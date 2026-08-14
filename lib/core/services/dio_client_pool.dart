import 'dart:async';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/connection_manager.dart';
import 'package:dmx/core/services/power_monitor.dart';

/// Manages a bounded pool of Dio clients with LRU eviction and background-aware cleanup.
/// Task 1.2: Specialized Service for Dio instance management.
class DioClientPool {
  static const int _maxActiveClients = 20;
  final Map<Dio, DateTime> _clientCreationTimes = {};
  final Set<Dio> _activeClients = {};
  final Set<Dio> _reservedClients = {};
  final Map<Dio, Set<String>> _activeDownloadsPerClient = {};
  Timer? _cleanupTimer;

  DioClientPool() {
    _startCleanupTimer();
  }

  void _startCleanupTimer() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _performCleanup();
    });
  }

  void _performCleanup() {
    final now = DateTime.now();
    final isPowerConstrained =
        PowerMonitor.batterySaverMode == BatterySaverMode.aggressive ||
            PowerMonitor.screenOff;

    final reservedMaxAge = isPowerConstrained
        ? const Duration(minutes: 2)
        : const Duration(minutes: 10);
    final normalMaxAge = isPowerConstrained
        ? const Duration(minutes: 1)
        : const Duration(minutes: 5);

    final toRelease = <Dio>[];
    for (final client in _activeClients) {
      final hasActiveDownloads =
          _activeDownloadsPerClient[client]?.isNotEmpty ?? false;
      if (hasActiveDownloads) continue;

      final creationTime = _clientCreationTimes[client] ?? now;
      final age = now.difference(creationTime);
      final isReserved = _reservedClients.contains(client);

      final isStale = isReserved
          ? age > reservedMaxAge
          : age > normalMaxAge;

      if (isStale) {
        toRelease.add(client);
      }
    }

    for (final client in toRelease) {
      releaseClient(client);
    }
  }

  Dio acquireClient({
    String? url,
    String? customUserAgent,
    String? referer,
    String? cookies,
    String? oauthToken,
  }) {
    // Evict oldest if pool is full
    while (_activeClients.length >= _maxActiveClients) {
      Dio? oldestClient;
      DateTime? oldestTime;

      for (final client in _activeClients) {
        // Skip clients with active downloads
        if (_activeDownloadsPerClient[client]?.isNotEmpty ?? false) continue;

        final created = _clientCreationTimes[client] ?? DateTime.now();
        if (oldestTime == null || created.isBefore(oldestTime)) {
          oldestTime = created;
          oldestClient = client;
        }
      }

      if (oldestClient != null) {
        releaseClient(oldestClient);
      } else {
        // All clients are busy, break and allow growth (though strictly should not happen with 20 limit)
        break;
      }
    }

    final client = buildTransferDio(
      url: url,
      customUserAgent: customUserAgent,
      referer: referer,
      cookies: cookies,
      oauthToken: oauthToken,
    );

    _activeClients.add(client);
    _reservedClients.add(client);
    _clientCreationTimes[client] = DateTime.now();
    _activeDownloadsPerClient[client] = {};

    return client;
  }

  void releaseClient(Dio client) {
    _reservedClients.remove(client);
    _activeClients.remove(client);
    _clientCreationTimes.remove(client);
    _activeDownloadsPerClient.remove(client);
    try {
      client.close(force: true);
    } catch (_) {}
  }

  void registerDownload(Dio client, String taskId) {
    _activeDownloadsPerClient[client]?.add(taskId);
  }

  void unregisterDownload(Dio client, String taskId) {
    _activeDownloadsPerClient[client]?.remove(taskId);
  }

  void dispose() {
    _cleanupTimer?.cancel();
    for (final client in _activeClients) {
      try {
        client.close(force: true);
      } catch (_) {}
    }
    _activeClients.clear();
    _reservedClients.clear();
    _clientCreationTimes.clear();
    _activeDownloadsPerClient.clear();
  }
}
