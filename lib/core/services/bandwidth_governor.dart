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
  DateTime _lastRefill = DateTime.now();

  final Lock _lock = Lock();

  BandwidthGovernor([this._globalBytesPerSecond = 0, double burstFactor = 1.0])
      : _burstFactor = burstFactor.clamp(1.0, 4.0);

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
    return _globalBytesPerSecond ~/ _activeConsumers;
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
    _availableTokens = 0;
  }

  /// Unregisters a consumer.
  void unregisterConsumer() {
    if (_activeConsumers > 0) {
      _activeConsumers--;
    }
  }

  /// Returns how many milliseconds the caller should sleep before writing
  /// [bytes] to stay within the configured limit.
  Future<int> acquire(int bytes) async {
    if (bytes <= 0) return 0;
    if (isUnlimited) return 0;

    return _lock.synchronized(() {
      _refill();

      final share = perConsumerBytesPerSecond;
      if (share <= 0) return 0;

      _availableTokens -= bytes;
      if (_availableTokens >= 0) {
        return 0;
      }

      final deficit = -_availableTokens;

      // Return the wait time required to repay token debt.
      final waitMs = (deficit / share * 1000.0).ceil();
      return waitMs.clamp(0, 30000); // Cap at 30s to avoid infinite waits on edge cases
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

    // FIX(13): burst window is now configurable; with _burstFactor == 1.0 the
    // governor never exceeds the configured per-consumer limit.
    _availableTokens = min(_availableTokens + newTokens, share * _burstFactor);

    _lastRefill = now;
  }
}
