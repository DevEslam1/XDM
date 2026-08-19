import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../interfaces/i_torrent_service.dart';

/// Manages stall and aliveness periodic watchdogs for active torrent downloads.
class TorrentWatchdogManager {
  final ITorrentService _torrentService;
  final int _torrentId;
  final Duration _watchdogInterval;

  Timer? _stallTimer;
  Timer? _alivenessTimer;

  TorrentWatchdogManager(
    this._torrentService,
    this._torrentId,
    this._watchdogInterval,
  );

  bool get isActive => _stallTimer != null || _alivenessTimer != null;

  void start({
    required VoidCallback onStalled,
    required VoidCallback onAlivenessLost,
  }) {
    stop();
    _stallTimer = Timer.periodic(_watchdogInterval, (_) => onStalled());
    _alivenessTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_torrentService.isTorrentAlive(_torrentId)) {
        onAlivenessLost();
      }
    });
  }

  void stop() {
    _stallTimer?.cancel();
    _stallTimer = null;
    _alivenessTimer?.cancel();
    _alivenessTimer = null;
  }

  void dispose() => stop();
}
