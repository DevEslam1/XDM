import 'dart:async';
import 'package:logging/logging.dart';

class BandwidthGovernor {
  static final _log = Logger('BandwidthGovernor');
  int _globalBytesPerSecond;
  int _activeConsumers = 0;
  double _availableTokens = 0;
  DateTime _lastRefill = DateTime.now();
  Future<void> _lock = Future.value();

  BandwidthGovernor([this._globalBytesPerSecond = 0]);

  void setGlobalLimit(int bytesPerSecond) {
    _globalBytesPerSecond = bytesPerSecond;
    _log.info(
      'Global bandwidth limit set to '
      '${bytesPerSecond > 0 ? '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB/s' : 'unlimited'}',
    );
  }

  void registerConsumer() {
    _activeConsumers++;
    _log.fine('Consumer registered. Active: $_activeConsumers');
  }

  void unregisterConsumer() {
    _activeConsumers = (_activeConsumers - 1).clamp(0, 999);
    _log.fine('Consumer unregistered. Active: $_activeConsumers');
  }

  int get perConsumerBytesPerSecond {
    if (_globalBytesPerSecond <= 0 || _activeConsumers <= 0) return 0;
    return _globalBytesPerSecond ~/ _activeConsumers;
  }

  bool get isUnlimited => _globalBytesPerSecond <= 0;

  Future<int> acquire(int bytes) async {
    if (_globalBytesPerSecond <= 0) return 0;

    final completer = Completer<int>();
    _lock = _lock.then((_) {
      try {
        _refill();
        final share = perConsumerBytesPerSecond;
        if (share <= 0) {
          completer.complete(0);
          return;
        }

        if (_availableTokens >= bytes) {
          _availableTokens -= bytes;
          completer.complete(0);
          return;
        }

        final deficit = bytes - _availableTokens;
        final waitMs = (deficit / share * 1000).round();
        _availableTokens = 0;

        completer.complete(waitMs.clamp(0, 200));
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
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
