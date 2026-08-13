import 'dart:collection';
import 'dart:math';

import 'package:synchronized/synchronized.dart';

/// A token-bucket bandwidth governor.
///
/// This class is safe to use per-download or per-engine.
/// In the current DMX architecture it is typically used per HTTP download job,
/// while the effective per-task limit is supplied by the engine.
class BandwidthGovernor {
  int _globalBytesPerSecond;
  int _activeConsumers = 0;

  /// FIX(13): how far above the per-consumer share the token bucket may burst.
  /// 1.0 = strict (never exceeds the configured limit); higher values allow
  /// short bursts. Configurable so users can trade strictness for speed.
  double _burstFactor;

  double _availableTokens = 0;
  // FIX: Initialize _lastRefill to 1 second in the past so the first acquire()
  // call gets a full second of tokens (up to the burst cap). Previously the
  // bucket started empty, causing unnecessary latency on the first write.
  DateTime _lastRefill = DateTime.now().subtract(const Duration(seconds: 1));

  final Lock _lock = Lock();
  double throttleFactor;

  BandwidthGovernor([
    this._globalBytesPerSecond = 0,
    double burstFactor = 1.0,
    this.throttleFactor = 1.0,
  ]) : _burstFactor = burstFactor.clamp(1.0, 4.0);

  void dispose() {}

  /// True when power monitoring is active and throttling bandwidth.
  bool get powerThrottleActive => throttleFactor < 1.0;

  int get globalBytesPerSecond => _globalBytesPerSecond;

  int get activeConsumers => _activeConsumers;

  double get burstFactor => _burstFactor;

  /// FIX(13): change the burst allowance at runtime. Values below 1.0 are
  /// clamped to 1.0 (strict), values above 4.0 are clamped to 4.0.
  void setBurstFactor(double factor) {
    _burstFactor = factor.clamp(1.0, 4.0);
  }

  bool get isUnlimited => _globalBytesPerSecond <= 0 || _activeConsumers <= 0;

  int get perConsumerBytesPerSecond {
    if (_globalBytesPerSecond <= 0 || _activeConsumers <= 0) return 0;
    // FIX-M6: Ensure at least 1 to avoid division by zero from a race
    // where _activeConsumers is decremented to 0 between isUnlimited and here.
    final consumers = max(1, _activeConsumers);
    final baseShare = _globalBytesPerSecond ~/ consumers;
    return (baseShare * throttleFactor).round();
  }

  /// Updates the global limit at runtime.
  void setGlobalLimit(int bytesPerSecond) {
    _globalBytesPerSecond = bytesPerSecond <= 0 ? 0 : bytesPerSecond;
  }

  /// Alias used by newer engine code.
  void updateLimit(int bytesPerSecond) => setGlobalLimit(bytesPerSecond);

  /// Alias kept for compatibility.
  void setLimit(int bytesPerSecond) => setGlobalLimit(bytesPerSecond);

  /// Registers a consumer.
  ///
  /// This is intentionally synchronous because in Dart isolates there is no
  /// true shared-memory concurrency for this object instance.
  void registerConsumer() {
    _activeConsumers++;
  }

  /// Unregisters a consumer.
  void unregisterConsumer() {
    if (_activeConsumers > 0) {
      _activeConsumers--;
    }
  }

  final Map<String, int> _taskLimits = {};
  final Map<String, DateTime> _taskLastRefill = {};

  void setTaskLimit(String taskId, int limit) {
    _taskLimits[taskId] = limit;
  }

  void removeTaskLimit(String taskId) {
    _taskLimits.remove(taskId);
    _taskLastRefill.remove(taskId);
    _taskTokens.remove(taskId);
  }

  int? getTaskLimit(String taskId) {
    return _taskLimits[taskId];
  }

  // FIX: Per-task token buckets so tasks with different limits don't
  // corrupt each other's rate-limiting through the shared _availableTokens.
  final Map<String, double> _taskTokens = {};

  /// Returns how many milliseconds the caller should sleep before writing
  /// [bytes] to stay within the configured limit.
  Future<int> acquire(int bytes, {String? taskId}) async {
    if (bytes <= 0) return 0;

    if (taskId != null && _taskLimits.containsKey(taskId)) {
      final taskLimit = _taskLimits[taskId]!;
      if (taskLimit <= 0) return 1000; // Blocked

      return _lock.synchronized(() {
        _refill();
        final now = DateTime.now();
        final last = _taskLastRefill[taskId] ?? now;
        final elapsedMs = now.difference(last).inMilliseconds;
        final tokens = _taskTokens[taskId] ?? 0.0;

        if (elapsedMs > 0) {
          final newTokens = taskLimit * elapsedMs / 1000.0;
          _taskTokens[taskId] =
              min(tokens + newTokens, taskLimit * _burstFactor);
          _taskLastRefill[taskId] = now;
        } else {
          _taskTokens[taskId] = tokens;
        }

        _taskTokens[taskId] = (_taskTokens[taskId] ?? 0) - bytes;
        final maxDeficit = -(taskLimit * 0.5);
        if ((_taskTokens[taskId] ?? 0) < maxDeficit) {
          _taskTokens[taskId] = maxDeficit;
        }
        if ((_taskTokens[taskId] ?? 0) >= 0) {
          return 0;
        }

        final deficit = -(_taskTokens[taskId] ?? 0);
        final waitMs = (deficit / taskLimit * 1000.0).ceil();
        return waitMs.clamp(0, 1000);
      });
    }

    if (isUnlimited) return 0;

    return _lock.synchronized(() {
      _refill();

      final share = perConsumerBytesPerSecond;
      // FIX: When share <= 0 due to extreme power throttling
      // (throttleFactor == 0), the governor should BLOCK writes, not
      // allow them unlimited. Returning 0 would bypass the limit.
      if (share <= 0) return 1000;

      _availableTokens -= bytes;
      final maxDeficit = -(share * 0.5);
      if (_availableTokens < maxDeficit) {
        _availableTokens = maxDeficit;
      }
      if (_availableTokens >= 0) {
        return 0;
      }

      final deficit = -_availableTokens;

      final waitMs = (deficit / share * 1000.0).ceil();
      return waitMs.clamp(0, 1000);
    });
  }

  void _refill() {
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastRefill).inMilliseconds;

    if (elapsedMs <= 0) return;

    final share = perConsumerBytesPerSecond;
    if (share <= 0) {
      _availableTokens = 0;
      _lastRefill = now;
      return;
    }

    final newTokens = share * elapsedMs / 1000.0;

    _availableTokens = min(_availableTokens + newTokens, share * _burstFactor);

    _lastRefill = now;
  }

  // ---------------------------------------------------------------------------
  // Per-Domain Bandwidth Tracking
  // ---------------------------------------------------------------------------
  final Map<String, _DomainState> _domainStates = {};

  void reportDomainSpeed(String domain, double bytesPerSecond) {
    if (domain.isEmpty) return;
    final state = _domainStates.putIfAbsent(domain, () => _DomainState());
    state.updateSpeed(bytesPerSecond);
  }

  double getAverageSpeedForDomain(String domain) {
    return _domainStates[domain]?.averageSpeed ?? 0.0;
  }
}

class _DomainState {
  final Queue<double> _speedHistory = Queue<double>();

  double get averageSpeed => _speedHistory.isEmpty
      ? 0
      : _speedHistory.reduce((a, b) => a + b) / _speedHistory.length;

  void updateSpeed(double speed) {
    _speedHistory.add(speed);
    if (_speedHistory.length > 20) {
      _speedHistory.removeFirst();
    }
  }
}
