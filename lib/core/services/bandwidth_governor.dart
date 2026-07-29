import 'dart:math';

import 'package:synchronized/synchronized.dart';

/// A token-bucket bandwidth governor.
///
/// This class is safe to use per-download or per-engine.
/// In the current DMX architecture it is typically used per HTTP download job,
/// while the effective per-task limit is supplied by the engine.
class BandwidthGovernor {
  static const int _maxSleepMs = 5000;

  int _globalBytesPerSecond;
  int _activeConsumers = 0;

  double _availableTokens = 0;
  DateTime _lastRefill = DateTime.now();

  final Lock _lock = Lock();

  BandwidthGovernor([this._globalBytesPerSecond = 0]);

  int get globalBytesPerSecond => _globalBytesPerSecond;

  int get activeConsumers => _activeConsumers;

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

      if (_availableTokens >= bytes) {
        _availableTokens -= bytes;
        return 0;
      }

      final deficit = bytes - _availableTokens;
      _availableTokens = 0;

      final waitMs = (deficit / share * 1000.0).ceil();
      return waitMs.clamp(0, _maxSleepMs);
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

    // Allow a small burst window, but keep it bounded.
    _availableTokens = min(_availableTokens + newTokens, share * 2.0);

    _lastRefill = now;
  }
}
