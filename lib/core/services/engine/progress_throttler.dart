import 'dart:async';
import 'package:dmx/core/services/power_monitor.dart';

/// Decouples progress emission from transfer engine loop with power-aware throttling.
class ProgressThrottler {
  final Duration Function() getForegroundInterval;
  final Duration Function() getBackgroundInterval;
  final void Function(Map<String, dynamic> progressData) onEmit;

  Timer? _throttleTimer;
  Map<String, dynamic>? _pendingProgress;
  DateTime? _lastEmitTime;

  ProgressThrottler({
    required this.getForegroundInterval,
    required this.getBackgroundInterval,
    required this.onEmit,
  });

  /// Reports progress payload with optional terminal immediate flush.
  void report(Map<String, dynamic> progressData, {bool isTerminal = false}) {
    if (isTerminal) {
      _throttleTimer?.cancel();
      _throttleTimer = null;
      _pendingProgress = null;
      _lastEmitTime = DateTime.now();
      onEmit(progressData);
      return;
    }

    final isBackground = PowerMonitor.screenOff;
    if (isBackground) return;

    final interval = getForegroundInterval();
    final now = DateTime.now();
    final canEmitNow = _lastEmitTime == null ||
        now.difference(_lastEmitTime!) >= interval;

    if (canEmitNow) {
      _throttleTimer?.cancel();
      _throttleTimer = null;
      _pendingProgress = null;
      _lastEmitTime = now;
      onEmit(progressData);
    } else {
      _pendingProgress = progressData;
      if (_throttleTimer == null) {
        final elapsedMs = now.difference(_lastEmitTime!).inMilliseconds;
        final remainingMs = interval.inMilliseconds - elapsedMs;
        _throttleTimer = Timer(
          Duration(
            milliseconds: remainingMs.clamp(1, interval.inMilliseconds),
          ),
          () {
            _throttleTimer = null;
            if (_pendingProgress != null) {
              _lastEmitTime = DateTime.now();
              onEmit(_pendingProgress!);
              _pendingProgress = null;
            }
          },
        );
      }
    }
  }

  void dispose() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _pendingProgress = null;
  }
}
