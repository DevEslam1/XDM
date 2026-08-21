import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../interfaces/i_torrent_service.dart';

/// Manages stall and aliveness periodic watchdogs for active torrent downloads.
class TorrentWatchdogManager {
  final ITorrentService _torrentService;
  final int _torrentId;
  final Duration _watchdogInterval;
  bool _active = false;
  Timer? _stallTimer;
  Timer? _alivenessTimer;

  TorrentWatchdogManager(
    this._torrentService,
    this._torrentId,
    this._watchdogInterval,
  );

  bool get isActive => _active;

  void start({
    required VoidCallback onStalled,
    required VoidCallback onAlivenessLost,
    bool Function()? isPausedByUser,
  }) {
    stop();
    _active = true;
    _stallTimer = Timer.periodic(_watchdogInterval, (_) {
      if (_active && !(isPausedByUser?.call() ?? false)) {
        onStalled();
      }
    });
    _alivenessTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_active &&
          !(isPausedByUser?.call() ?? false) &&
          !_torrentService.isTorrentAlive(_torrentId)) {
        onAlivenessLost();
      }
    });
  }

  void stop() {
    _active = false;
    _stallTimer?.cancel();
    _stallTimer = null;
    _alivenessTimer?.cancel();
    _alivenessTimer = null;
  }

  void dispose() => stop();
}

