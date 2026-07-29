import 'dart:async';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

class BandwidthGovernor {
  static final _log = Logger('BandwidthGovernor');
  int _globalBytesPerSecond;
  int _activeConsumers = 0;
  double _availableTokens = 0;
  DateTime _lastRefill = DateTime.now();
  final Lock _lock = Lock();

  BandwidthGovernor([this._globalBytesPerSecond = 0]);

  void setGlobalLimit(int bytesPerSecond) {
    _globalBytesPerSecond = bytesPerSecond;
    _log.info(
      'Global bandwidth limit set to '
      '${bytesPerSecond > 0 ? '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB/s' : 'unlimited'}',
    );
  }

  void registerConsumer() {
    unawaited(
      _lock.synchronized(() async {
        _activeConsumers++;
        _log.fine('Consumer registered. Active: $_activeConsumers');
      }),
    );
  }

  void unregisterConsumer() {
    unawaited(
      _lock.synchronized(() async {
        _activeConsumers = (_activeConsumers - 1).clamp(0, 999);
        _log.fine('Consumer unregistered. Active: $_activeConsumers');
      }),
    );
  }

  int get perConsumerBytesPerSecond {
    if (_globalBytesPerSecond <= 0 || _activeConsumers <= 0) return 0;
    return _globalBytesPerSecond ~/ _activeConsumers;
  }

  bool get isUnlimited => _globalBytesPerSecond <= 0;

  Future<int> acquire(int bytes) async {
    if (_globalBytesPerSecond <= 0) return 0;

    return _lock.synchronized(() {
      _refill();
      final share = perConsumerBytesPerSecond;
      if (share <= 0) return 0;

      if (_availableTokens >= bytes) {
        _availableTokens -= bytes;
        return 0;
      }

      final deficit = bytes - _availableTokens;
      final waitMs = (deficit / share * 1000).round();
      _availableTokens = 0;

      // Allow up to 5 s sleep to avoid busy-looping at low speed limits.
      // At 10 KB/s a 64 KB chunk needs ~6.4 s; sleeping the full deficit
      // (capped at 5 s) keeps CPU near-zero between chunks.
      return waitMs.clamp(0, 5000);
    });
  }

  void _refill() {
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastRefill).inMilliseconds;
    if (elapsedMs <= 0) return;

    final share = perConsumerBytesPerSecond;
    if (share <= 0) return;

    final newTokens = share * elapsedMs / 1000.0;
    _availableTokens = (_availableTokens + newTokens).clamp(0, share * 2.0);
    _lastRefill = now;
  }
}
