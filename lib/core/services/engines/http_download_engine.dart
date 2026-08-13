import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/services/download_journal.dart';
import '../../../core/services/power_monitor.dart';
import 'package:dmx/features/downloads/models/download_task.dart';

// ═══════════════════════════════════════════════════════════════════════════
// CHUNK SCHEDULING — pure functions, no I/O, fully unit-testable.
// Execution lives in the engine's isolate jobs; a chunk executor can only
// ever write inside its own ChunkState range.
// ═══════════════════════════════════════════════════════════════════════════

class ChunkScheduler {
  ChunkScheduler._();

  /// Files smaller than this never benefit from parallel ranges.
  static const int minSizeForMultithread = 512 * 1024;

  /// Fixed partition of [totalSize] into [threadCount] contiguous ranges.
  /// This layout is IDENTICAL to the legacy v2 layout, which makes v2→v3
  /// migration a 1:1 mapping of the `progress` array.
  static List<ChunkState> plan({
    required int totalSize,
    required int threadCount,
  }) {
    if (totalSize <= 0) {
      return [ChunkState(start: 0, end: -1)];
    }
    var n = threadCount.clamp(1, 32);
    if (totalSize < minSizeForMultithread) n = 1;
    if (totalSize < n * 1024) n = 1;
    final part = totalSize ~/ n;
    return List<ChunkState>.generate(n, (i) {
      final start = i * part;
      final end = (i == n - 1) ? totalSize - 1 : start + part - 1;
      return ChunkState(start: start, end: end);
    });
  }

  /// Rebuilds a layout for resume: keeps completed chunks, returns only the
  /// ranges that still need work (each starting at its saved high-water
  /// mark). Chunk failures therefore retry ONLY the affected range.
  static List<ChunkState> pendingWork(List<ChunkState> chunks) =>
      chunks.where((c) => !c.isComplete).toList();

  /// Collapses any layout into a single open-ended chunk (fallback when the
  /// server turns out not to honor Range).
  static List<ChunkState> singleStream(int totalSize) => [
        ChunkState(
          start: 0,
          end: totalSize > 0 ? totalSize - 1 : -1,
        ),
      ];
}

// ═══════════════════════════════════════════════════════════════════════════
// ADAPTIVE THREAD MONITOR
//
// Collects throughput samples per task and publishes a recommendation for
// the NEXT start of that task. Deliberately not allowed to re-thread a
// running transfer: changing chunk layout mid-flight is exactly the class
// of mutation that produced the old drift bugs. The recommendation applies
// when the task next leaves the queue.
// ═══════════════════════════════════════════════════════════════════════════

class HttpDownloadEngine {
  final Map<String, _AdaptiveTracker> _trackers = {};
  Timer? _monitorTimer;

  void _ensureTimerRunning() {
    if (_trackers.isEmpty) {
      _monitorTimer?.cancel();
      _monitorTimer = null;
      return;
    }
    _monitorTimer?.cancel();
    final intervalSec = PowerMonitor.screenOff ? 30 : 5;
    _monitorTimer = Timer.periodic(
      Duration(seconds: intervalSec),
      (_) => _evaluate(),
    );
  }

  void startAdaptiveMonitorIfEnabled(DownloadTask task, bool enabled) {
    if (!enabled) return;
    _trackers.putIfAbsent(task.id, () => _AdaptiveTracker(task.threadCount));
    _ensureTimerRunning();
  }

  void startAdaptiveMonitorForTask(String taskId, int threadCount) {
    _trackers.putIfAbsent(taskId, () => _AdaptiveTracker(threadCount));
    _ensureTimerRunning();
  }

  void recordSample(String taskId, double bytesPerSec, int threads) {
    _trackers[taskId]?.add(bytesPerSec, threads);
  }

  void updateTrackerThreadCount(String taskId, int newThreadCount) {
    final tracker = _trackers[taskId];
    if (tracker != null) {
      tracker.updateThreadCount(newThreadCount);
    }
  }

  int recommendedThreads(String taskId, int fallback) {
    final t = _trackers[taskId];
    if (t == null) return fallback;
    return t.recommendation.clamp(1, fallback);
  }

  int get activeTrackerCount => _trackers.length;

  void stopFor(String taskId) {
    _trackers.remove(taskId);
    if (_trackers.isEmpty) {
      _monitorTimer?.cancel();
      _monitorTimer = null;
    }
  }

  void pauseAll() {
    _monitorTimer?.cancel();
    _monitorTimer = null;
  }

  void resumeAll() {
    if (_trackers.isNotEmpty) {
      _ensureTimerRunning();
    }
  }

  void stopAdaptiveThreadMonitor() {
    _monitorTimer?.cancel();
    _monitorTimer = null;
    _trackers.clear();
  }

  void _evaluate() {
    if (PowerMonitor.screenOff) return;
    for (final tracker in _trackers.values) {
      tracker.evaluate();
    }
  }
}

class _AdaptiveTracker {
  // FIX: Changed from final to mutable so updateThreadCount() can refresh
  // the tracker when a task restarts with a different thread count.
  int currentThreads;

  _AdaptiveTracker(this.currentThreads);

  final Queue<double> _samples = Queue<double>();
  final Queue<int> _sampleThreads = Queue<int>();
  int recommendation = 0;

  /// Updates the current thread count and clears any stale recommendation
  /// so the next evaluation uses the new baseline.
  void updateThreadCount(int newCount) {
    if (newCount != currentThreads) {
      currentThreads = newCount;
      recommendation = 0;
    }
  }

  void add(double bytesPerSec, int threads) {
    if (bytesPerSec > 0) {
      _samples.add(bytesPerSec);
      _sampleThreads.add(threads);
      if (_samples.length > 12) {
        _samples.removeFirst();
        _sampleThreads.removeFirst();
      }
    }
  }

  /// Average per-thread throughput from recent samples.
  double get averagePerThreadSpeed {
    if (_samples.isEmpty) return 0;
    double sum = 0;
    final samplesList = _samples.toList();
    final threadsList = _sampleThreads.toList();
    for (var i = 0; i < samplesList.length; i++) {
      final t = threadsList[i] > 0 ? threadsList[i] : 1;
      sum += samplesList[i] / t;
    }
    return sum / samplesList.length;
  }

  /// Plateau detection: three consecutive samples within ±5% mean more
  /// parallelism is not helping → recommend shedding threads on next start.
  /// The recommendation is re-evaluated continuously: if speed improves after
  /// a plateau was detected, the stale recommendation is cleared so the next
  /// start uses the original (higher) thread count.
  void evaluate() {
    if (_samples.length < 6) return;
    final tail = _samples.toList().sublist(_samples.length - 3);
    final avg = tail.reduce((a, b) => a + b) / tail.length;
    if (avg <= 0) {
      recommendation = 0;
      return;
    }
    final plateau = tail.every((s) => (s - avg).abs() / avg < 0.05);
    if (plateau && currentThreads > 1) {
      final newRec = (currentThreads / 2).ceil().clamp(1, currentThreads);
      if (recommendation != newRec) {
        recommendation = newRec;
        debugPrint('[AdaptiveThreads] plateau at ${avg ~/ 1024} KB/s with '
            '$currentThreads threads → next start uses $recommendation');
      }
    } else if (!plateau && recommendation != 0) {
      // Speed is no longer plateaued — clear stale recommendation.
      recommendation = 0;
    }
  }
}
