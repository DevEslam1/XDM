import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../interfaces/i_torrent_service.dart';

/// Manages stall and aliveness periodic watchdogs for active torrent downloads.
/// Centralized single watchdog system for the torrent download cycle.
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
  Timer? get stallTimer => _stallTimer;
  Timer? get alivenessTimer => _alivenessTimer;

  // FIX(N7): rename onStalled to onStallCheck with backwards compatible fallback
  void start({
    VoidCallback? onStallCheck,
    VoidCallback? onStalled,
    required VoidCallback onAlivenessLost,
    bool Function()? isPausedByUser,
  }) {
    stop();
    final stallCallback = onStallCheck ?? onStalled;
    if (stallCallback == null) {
      throw ArgumentError('Either onStallCheck or onStalled must be provided');
    }
    _active = true;
    _stallTimer = Timer.periodic(_watchdogInterval, (_) {
      if (_active && !(isPausedByUser?.call() ?? false)) {
        stallCallback();
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
