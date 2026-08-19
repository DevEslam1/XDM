import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'power_monitor.dart';

/// A token-bucket bandwidth governor.
///
/// This class is safe to use per-download or per-engine.
/// In the current DMX architecture it is typically used per HTTP download job,
/// while the effective per-task limit is supplied by the engine.
class BandwidthGovernor {
  /// Special limit value indicating no bandwidth restriction (unlimited).
  static const int unlimited = 0;

  int _globalBytesPerSecond;
  int _activeConsumers = 0;

  double _burstFactor;
  double _availableTokens = 0;
  DateTime _lastRefill = DateTime.now().subtract(const Duration(seconds: 1));
  // FIX-P1-02: Refill throttle — skip token arithmetic when the previous
  // refill happened less than 50ms ago so a burst of acquire() calls does not
  // re-run DateTime.now() + float math on every single probe.
  int _lastRefillMs = 0;
  static const int _minRefillIntervalMs = 50;

  /// Milliseconds since epoch of the most recent refill. Testing hook.
  @visibleForTesting
  int get lastRefillMsForTesting => _lastRefillMs;

  BandwidthGovernor([
    this._globalBytesPerSecond = 0,
    double burstFactor = 1.5,
    double? throttleFactor,
  ]) : _burstFactor = burstFactor.clamp(1.0, 1.5) {
    PowerMonitor.throttleFactorNotifier.addListener(onPowerStateChanged);
  }

  /// Refills tokens whenever power/battery throttling state changes.
  void onPowerStateChanged() => _refill();

  /// Periodically drops domain states that have been idle for > 10 min so the
  /// in-memory map cannot grow unbounded on long-running jobs.
  Timer? _domainCleanupTimer;

  @visibleForTesting
  Timer? get domainCleanupTimerForTesting => _domainCleanupTimer;

  void _startDomainCleanup() {
    _domainCleanupTimer?.cancel();
    _domainCleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _cleanupStaleDomainStates();
    });
  }

  void _cleanupStaleDomainStates() {
    if (_domainStates.isEmpty) return;
    final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
    _domainStates.removeWhere((_, state) => state.lastUpdated.isBefore(cutoff));
  }

  /// Releases all per-task and per-domain tracking state and cancels timers.
  void dispose() {
    PowerMonitor.throttleFactorNotifier.removeListener(onPowerStateChanged);
    _domainCleanupTimer?.cancel();
    _domainCleanupTimer = null;
    _taskLimits.clear();
    _taskLastRefill.clear();
    _taskTokens.clear();
    _domainStates.clear();
  }

  /// Live throttle factor derived from current battery and power policy.
  double get throttleFactor => PowerMonitor.throttleFactor;

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
    if (_activeConsumers == 1) {
      _startDomainCleanup();
    }
  }

  /// Unregisters a consumer.
  void unregisterConsumer() {
    if (_activeConsumers > 0) {
      _activeConsumers--;
      if (_activeConsumers == 0) {
        _domainCleanupTimer?.cancel();
        _domainCleanupTimer = null;
      }
    }
  }

  final Map<String, int> _taskLimits = {};
  final Map<String, DateTime> _taskLastRefill = {};

  void setTaskLimit(String taskId, int limit) {
    _taskLimits[taskId] = limit;
    _taskLastRefill[taskId] ??=
        DateTime.now().subtract(const Duration(seconds: 1));
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
    return acquireNonBlocking(bytes, taskId: taskId);
  }

  /// Blocking variant of [acquire] that awaits the calculated delay (if any)
  /// before returning the waited milliseconds.
  Future<int> acquireBlocking(int bytes, {String? taskId}) async {
    final waitMs = acquireNonBlocking(bytes, taskId: taskId);
    if (waitMs > 0) {
      await Future.delayed(Duration(milliseconds: waitMs));
    }
    return waitMs;
  }

  /// Non-blocking variant of [acquire] for probe requests. Returns the required wait
  /// in milliseconds without suspending execution.
  int acquireNonBlocking(int bytes, {String? taskId}) {
    if (bytes <= 0) return 0;

    if (taskId != null && _taskLimits.containsKey(taskId)) {
      return _acquireTaskLimited(bytes, taskId);
    }

    if (isUnlimited) return 0;
    return _acquireGlobal(bytes);
  }

  static const int _maxThrottleWaitMs = 1000;

  int _acquireTaskLimited(int bytes, String taskId) {
    final rawLimit = _taskLimits[taskId]!;
    final taskLimit = (rawLimit * throttleFactor).round();
    if (taskLimit <= 0) return _maxThrottleWaitMs;
    final now = DateTime.now();
    final last =
        _taskLastRefill[taskId] ?? now.subtract(const Duration(seconds: 1));
    final elapsedMs = now.difference(last).inMilliseconds;
    final tokens = _taskTokens[taskId] ?? 0.0;
    var currentTokens = tokens;
    if (elapsedMs > 0) {
      final newTokens = taskLimit * elapsedMs / 1000.0;
      currentTokens = min(tokens + newTokens, taskLimit * _burstFactor);
    }
    currentTokens -= bytes;
    _taskTokens[taskId] = currentTokens;

    int waitMs = 0;
    if (currentTokens < 0) {
      final deficit = -currentTokens;
      final burstAllowance = taskLimit * (_burstFactor - 1.0);
      final effectiveDeficit = max(0.0, deficit - burstAllowance);
      waitMs = (effectiveDeficit / taskLimit * 1000.0).ceil();
      _taskTokens[taskId] = 0;
    }
    _taskLastRefill[taskId] = now;
    return waitMs.clamp(0, _maxThrottleWaitMs);
  }

  int _acquireGlobal(int bytes) {
    _refill();
    final share = perConsumerBytesPerSecond;
    if (share <= 0) return _maxThrottleWaitMs;
    _availableTokens -= bytes;
    if (_availableTokens < 0) {
      final deficit = -_availableTokens;
      final waitMs = (deficit / share * 1000.0).ceil();
      return waitMs.clamp(0, _maxThrottleWaitMs);
    }
    return 0;
  }

  void _refill() {
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastRefill).inMilliseconds;

    if (elapsedMs < _minRefillIntervalMs) return;
    _lastRefill = now;
    _lastRefillMs = now.millisecondsSinceEpoch;

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
  DateTime lastUpdated = DateTime.now();

  double get averageSpeed => _speedHistory.isEmpty
      ? 0
      : _speedHistory.reduce((a, b) => a + b) / _speedHistory.length;

  void updateSpeed(double speed) {
    _speedHistory.add(speed);
    lastUpdated = DateTime.now();
    if (_speedHistory.length > 20) {
      _speedHistory.removeFirst();
    }
  }
}
