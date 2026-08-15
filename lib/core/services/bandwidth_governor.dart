import 'dart:collection';
import 'dart:math';

import 'power_monitor.dart';

/// A token-bucket bandwidth governor.
///
/// This class is safe to use per-download or per-engine.
/// In the current DMX architecture it is typically used per HTTP download job,
/// while the effective per-task limit is supplied by the engine.
class BandwidthGovernor {
  int _globalBytesPerSecond;
  int _activeConsumers = 0;

  double _burstFactor;
  double _availableTokens = 0;
  DateTime _lastRefill = DateTime.now().subtract(const Duration(seconds: 1));
  double throttleFactor;

  BandwidthGovernor([
    this._globalBytesPerSecond = 0,
    double burstFactor = 1.5,
    double? throttleFactor,
  ])  : _burstFactor = burstFactor.clamp(1.0, 1.5),
        throttleFactor = throttleFactor ?? PowerMonitor.throttleFactor;

  void dispose() {}

  /// True when power monitoring is active and throttling bandwidth.
  bool get powerThrottleActive => throttleFactor < 1.0;

  int get globalBytesPerSecond => _globalBytesPerSecond;

  int get activeConsumers => _activeConsumers;

  double get burstFactor => _burstFactor;

  /// Clamps burst allowance to 1.0 (strict) - 1.5x (S-01 burst clamp).
  void setBurstFactor(double factor) {
    _burstFactor = factor.clamp(1.0, 1.5);
  }

  bool get isUnlimited => _globalBytesPerSecond <= 0 || _activeConsumers <= 0;

  int get perConsumerBytesPerSecond {
    if (_globalBytesPerSecond <= 0 || _activeConsumers <= 0) return 0;
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

  final Map<String, double> _taskTokens = {};

  /// Returns how many milliseconds the caller should sleep before writing
  /// [bytes] to stay within the configured limit.
  Future<int> acquire(int bytes, {String? taskId}) async {
    if (bytes <= 0) return 0;

    if (taskId != null && _taskLimits.containsKey(taskId)) {
      return _acquireTaskLimited(bytes, taskId);
    }

    if (isUnlimited) return 0;
    return _acquireGlobal(bytes);
  }

  int _acquireTaskLimited(int bytes, String taskId) {
    final rawLimit = _taskLimits[taskId]!;
    final taskLimit = (rawLimit * throttleFactor).round();
    if (taskLimit <= 0) return 1000;
    final now = DateTime.now();
    final last = _taskLastRefill[taskId] ?? now;
    final elapsedMs = now.difference(last).inMilliseconds;
    final tokens = _taskTokens[taskId] ?? 0.0;
    if (elapsedMs > 0) {
      final newTokens = taskLimit * elapsedMs / 1000.0;
      _taskTokens[taskId] = min(tokens + newTokens, taskLimit * _burstFactor);
      _taskLastRefill[taskId] = now;
    }
    final currentTokens = (_taskTokens[taskId] ?? 0) - bytes;
    _taskTokens[taskId] = currentTokens;
    if (currentTokens < 0) {
      final deficit = -currentTokens;
      final waitMs = (deficit / taskLimit * 1000.0).ceil();
      _taskTokens[taskId] = 0;
      return waitMs.clamp(0, 1000);
    }
    return 0;
  }

  int _acquireGlobal(int bytes) {
    _refill();
    final share = perConsumerBytesPerSecond;
    if (share <= 0) return 1000;
    _availableTokens -= bytes;
    if (_availableTokens < 0) {
      final deficit = -_availableTokens;
      final waitMs = (deficit / share * 1000.0).ceil();
      _availableTokens = 0;
      return waitMs.clamp(0, 1000);
    }
    return 0;
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
