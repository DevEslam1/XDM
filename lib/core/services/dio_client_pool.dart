import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/service_registry.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';

/// Manages a bounded pool of Dio clients with LRU eviction and background-aware cleanup.
/// Task 1.2: Specialized Service for Dio instance management.
class DioClientPool implements DisposableService, MemoryPressureListener {
  static final _log = LoggingService.logger('DioClientPool');
  static const int _maxActiveClients = 6;
  static const int _maxActiveClientsAggressive = 3;
  final Map<Dio, DateTime> _clientCreationTimes = {};
  final Set<Dio> _activeClients = {};
  final Set<Dio> _reservedClients = {};
  final Map<Dio, Set<String>> _activeDownloadsPerClient = {};
  Timer? _cleanupTimer;

  DioClientPool() {
    _startCleanupTimer();
    ServiceRegistry.register(this);
    ServiceRegistry.registerMemoryPressureListener(this);
  }

  int get activeClientsCount => _activeClients.length;
  int get reservedClientsCount => _reservedClients.length;

  /// Effective client cap: drops to 3 while the aggressive battery-saver mode
  /// is active to minimize memory/CPU during constrained background downloads.
  int get _effectiveMaxClients =>
      PowerMonitor.batterySaverMode == BatterySaverMode.aggressive
          ? _maxActiveClientsAggressive
          : _maxActiveClients;

  void _startCleanupTimer() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _performCleanup();
    });
  }

  @override
  void onMemoryPressure() {
    final initialCount = _activeClients.length;
    final toRelease = <Dio>[];

    for (final client in _activeClients) {
      final hasActiveDownloads =
          _activeDownloadsPerClient[client]?.isNotEmpty ?? false;
      if (!hasActiveDownloads) {
        toRelease.add(client);
      }
    }

    for (final client in toRelease) {
      releaseClient(client);
    }

    // Halve the reserved pool
    final reservedToKeep = (_reservedClients.length / 2).floor();
    final reservedList = _reservedClients.toList();
    if (reservedList.length > reservedToKeep) {
      final excess = reservedList.sublist(reservedToKeep);
      for (final client in excess) {
        _reservedClients.remove(client);
      }
    }

    final evictedCount = initialCount - _activeClients.length;
    _log.info(
      '[DioClientPool] Memory pressure handled: evicted $evictedCount idle clients ($initialCount -> ${_activeClients.length})',
    );
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
    while (_activeClients.length >= _effectiveMaxClients) {
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
        // All clients are busy, break and allow growth
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

  @visibleForTesting
  Map<Dio, Set<String>> get activeDownloadsPerClient => _activeDownloadsPerClient;

  void releaseClient(Dio client) {
    _activeDownloadsPerClient[client]?.clear();
    _activeDownloadsPerClient.remove(client);
    _reservedClients.remove(client);
    _activeClients.remove(client);
    _clientCreationTimes.remove(client);
    try {
      client.close(force: true);
    } catch (e, st) {
      LoggingService.logger('DioClientPool').warning('Operation failed', e, st);
    }
  }

  void registerDownload(Dio client, String taskId) {
    _activeDownloadsPerClient.putIfAbsent(client, () => <String>{}).add(taskId);
  }

  void unregisterDownload(Dio client, String taskId) {
    final set = _activeDownloadsPerClient[client];
    set?.remove(taskId);
  }

  @override
  Future<void> dispose() async {
    ServiceRegistry.unregister(this);
    ServiceRegistry.unregisterMemoryPressureListener(this);
    _cleanupTimer?.cancel();
    for (final client in List<Dio>.from(_activeClients)) {
      try {
        client.close(force: true);
      } catch (e, st) {
      LoggingService.logger('DioClientPool').warning('Operation failed', e, st);
    }
    }
    _activeClients.clear();
    _reservedClients.clear();
    _clientCreationTimes.clear();
    _activeDownloadsPerClient.clear();
  }
}
