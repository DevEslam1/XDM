import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/service_registry.dart';
import 'package:flutter/foundation.dart';

/// Manages a bounded pool of Dio clients with LRU eviction and background-aware cleanup.
/// Task 1.2: Specialized Service for Dio instance management.
class DioClientPool implements DisposableService, MemoryPressureListener {
  static final _log = LoggingService.logger('DioClientPool');
  static const int _maxActiveClients = 6;
  static const int _maxActiveClientsAggressive = 3;
  static const int _maxIdleHosts = 10;
  final Map<Dio, DateTime> _clientCreationTimes = {};
  final Set<Dio> _activeClients = {};
  final Set<Dio> _reservedClients = {};
  final Map<Dio, Set<String>> _activeDownloadsPerClient = {};
  final LinkedHashMap<String, Dio> _idleClientsByHost = LinkedHashMap<String, Dio>();
  final Map<Dio, String> _clientHosts = {};

  /// FIX-P1-06: Debounce timer for stale-idle cleanup. Multiple releases in a
  /// burst coalesce into a single run 1s after the last one.
  Timer? _cleanupDebounceTimer;
  static const Duration _cleanupDebounce = Duration(seconds: 1);

  DioClientPool({bool enableCleanupTimer = false}) {
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
    // FIX-P1-06: Debounce — coalesce bursts of releaseClient() calls into a
    // single cleanup pass 1s after the last one.
    _cleanupDebounceTimer?.cancel();
    _cleanupDebounceTimer = Timer(_cleanupDebounce, () {
      _cleanupDebounceTimer = null;
      _runCleanup();
    });
  }

  void _runCleanup() {
    final now = DateTime.now();
    final isPowerConstrained =
        PowerMonitor.batterySaverMode == BatterySaverMode.aggressive ||
            PowerMonitor.screenOff;

    final maxAge = isPowerConstrained
        ? const Duration(minutes: 1)
        : const Duration(minutes: 5);

    final staleHosts = <String>[];
    for (final entry in _idleClientsByHost.entries) {
      final client = entry.value;
      final creationTime = _clientCreationTimes[client] ?? now;
      final age = now.difference(creationTime);
      if (age > maxAge) {
        staleHosts.add(entry.key);
      }
    }

    for (final host in staleHosts) {
      final client = _idleClientsByHost.remove(host);
      if (client != null) {
        _closeClient(client);
      }
    }
    if (staleHosts.isNotEmpty) {
      _log.fine(
        '[DioClientPool] Cleanup evicted ${staleHosts.length} stale idle client(s).',
      );
    }
  }

  Dio acquireClient({
    String? url,
    String? customUserAgent,
    String? referer,
    String? cookies,
    String? oauthToken,
  }) {
    final uri = url != null ? Uri.tryParse(url) : null;
    final host = uri?.host.toLowerCase() ?? '';

    // Reuse idle client for same host if available
    if (host.isNotEmpty && _idleClientsByHost.containsKey(host)) {
      final cached = _idleClientsByHost.remove(host);
      if (cached != null) {
        _clientCreationTimes[cached] = DateTime.now();
        buildTransferDio(
          url: url,
          customUserAgent: customUserAgent,
          referer: referer,
          cookies: cookies,
          oauthToken: oauthToken,
          pooled: cached,
        );
        return cached;
      }
    }

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
    if (host.isNotEmpty) {
      _clientHosts[client] = host;
    }

    return client;
  }

  @visibleForTesting
  Map<Dio, Set<String>> get activeDownloadsPerClient =>
      _activeDownloadsPerClient;

  @visibleForTesting
  Map<String, Dio> get idleClientsByHostForTesting => _idleClientsByHost;

  void releaseClient(Dio client) {
    final activeDownloads = _activeDownloadsPerClient[client];
    if (activeDownloads != null && activeDownloads.isNotEmpty) {
      _log.warning(
        '[DioClientPool] Attempted to release client with ${activeDownloads.length} active download(s); skipping force close.',
      );
      return;
    }
    _activeClients.remove(client);
    final host = _clientHosts[client];
    if (host != null && host.isNotEmpty) {
      final existing = _idleClientsByHost.remove(host);
      if (existing != null && !identical(existing, client)) {
        _closeClient(existing);
      }
      if (_idleClientsByHost.length >= _maxIdleHosts) {
        final oldestHost = _idleClientsByHost.keys.first;
        final evicted = _idleClientsByHost.remove(oldestHost);
        if (evicted != null) {
          _closeClient(evicted);
        }
      }
      _idleClientsByHost[host] = client;
      _performCleanup();
      return;
    }
    _closeClient(client);
    _performCleanup();
  }

  void _closeClient(Dio client) {
    _clientHosts.remove(client);
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
    _cleanupDebounceTimer?.cancel();
    _cleanupDebounceTimer = null;
    for (final client in List<Dio>.from(_activeClients)) {
      try {
        client.close(force: true);
      } catch (e, st) {
        LoggingService.logger('DioClientPool')
            .warning('Operation failed', e, st);
      }
    }
    _activeClients.clear();
    _reservedClients.clear();
    _clientCreationTimes.clear();
    _activeDownloadsPerClient.clear();
  }
}
