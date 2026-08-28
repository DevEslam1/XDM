import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dmx/core/domain/torrent_models.dart' show ProxyType;
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/service_registry.dart';
import 'package:flutter/foundation.dart';

/// Process-wide network policy (HTTPS-only enforcement + HTTP proxy) applied to
/// every Dio built by [DioClientPool]. Push-populated from the settings layer
/// (see `network_settings_page.dart`; a startup application seam is documented
/// there too). NOTE: this is main-isolate state only — the isolate-based HTTP
/// transfer path (`http_transfer_job` → `buildTransferDio`) does NOT consult it
/// and must receive settings via its TransferCommand instead.
class DioNetworkPolicy {
  DioNetworkPolicy._();

  /// Singleton snapshot mutated by the settings layer and read at request time.
  static final DioNetworkPolicy instance = DioNetworkPolicy._();

  bool httpsOnly = false;
  bool proxyEnabled = false;
  ProxyType proxyType = ProxyType.none;
  String proxyHost = '';
  int proxyPort = 0;
  String? proxyUsername;
  String? proxyPassword;

  /// Whether an HTTP(S) proxy is fully configured and usable by dart:io's
  /// [HttpClient]. SOCKS5 is intentionally excluded: dart:io HttpClient cannot
  /// route through SOCKS without an extra dependency (torrents already handle
  /// SOCKS5 natively via libtorrent).
  bool get httpProxyActive =>
      proxyEnabled &&
      proxyType == ProxyType.http &&
      proxyHost.isNotEmpty &&
      proxyPort > 0;

  void update({
    bool? httpsOnly,
    bool? enableProxy,
    ProxyType? proxyType,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
  }) {
    if (httpsOnly != null) this.httpsOnly = httpsOnly;
    if (enableProxy != null) proxyEnabled = enableProxy;
    if (proxyType != null) this.proxyType = proxyType;
    if (proxyHost != null) this.proxyHost = proxyHost;
    if (proxyPort != null) this.proxyPort = proxyPort;
    // Only touch credentials when explicitly supplied: pass an empty string to
    // clear, a non-empty string to set, or omit (null) to leave unchanged. This
    // lets callers update an unrelated field (e.g. update(httpsOnly: x)) without
    // clobbering stored proxy credentials.
    if (proxyUsername != null) {
      this.proxyUsername = proxyUsername.isEmpty ? null : proxyUsername;
    }
    if (proxyPassword != null) {
      this.proxyPassword = proxyPassword.isEmpty ? null : proxyPassword;
    }
  }
}

/// Refuses insecure `http://` requests while [DioNetworkPolicy.httpsOnly] is on.
/// Reads the flag dynamically so a single instance stays correct across policy
/// changes and pooled-client reuse.
class _HttpsOnlyInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (DioNetworkPolicy.instance.httpsOnly &&
        options.uri.scheme.toLowerCase() == 'http') {
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          error: 'HTTPS-only is enabled: refused insecure http:// request to '
              '${options.uri.host}. Disable HTTPS-only in Network settings or '
              'use an https:// URL.',
        ),
      );
      return;
    }
    handler.next(options);
  }
}

/// Manages a bounded pool of Dio clients with LRU eviction and background-aware cleanup.
/// Task 1.2: Specialized Service for Dio instance management.
class DioClientPool implements DisposableService, MemoryPressureListener {
  static final _log = LoggingService.logger('DioClientPool');
  static const int _maxActiveClients = 6;
  static const int _maxIdleHosts = 10;
  final Map<Dio, DateTime> _clientCreationTimes = {};
  final Set<Dio> _activeClients = {};
  final Set<Dio> _reservedClients = {};
  final Map<Dio, Set<String>> _activeDownloadsPerClient = {};
  final LinkedHashMap<String, Dio> _idleClientsByHost =
      LinkedHashMap<String, Dio>();
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

  /// Effective client cap: drops to 2 while in background, screen off, or aggressive battery saver.
  int get _effectiveMaxClients {
    if (DownloadEngine.isInBackground || PowerMonitor.screenOff) return 2;
    if (PowerMonitor.batterySaverMode == BatterySaverMode.aggressive) return 2;
    return _maxActiveClients;
  }

  @override
  void onMemoryPressure() {
    final initialCount = _activeClients.length;

    // Close ALL idle clients immediately
    for (final client in List<Dio>.from(_idleClientsByHost.values)) {
      _closeClient(client);
    }
    _idleClientsByHost.clear();

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
        // buildTransferDio re-sets createHttpClient on every acquire, so proxy
        // config must be re-layered here (the httpsOnly interceptor persists).
        _applyProxy(cached, url);
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

    // Enforce HTTPS-only (Task 3) and apply the HTTP proxy (Task 2). The
    // interceptor is added once per client (it reads the policy dynamically);
    // proxy config is (re)applied on every acquire since buildTransferDio
    // rebuilds the underlying HttpClient factory.
    if (!client.interceptors.any((i) => i is _HttpsOnlyInterceptor)) {
      client.interceptors.add(_HttpsOnlyInterceptor());
    }
    _applyProxy(client, url);

    _activeClients.add(client);
    _reservedClients.add(client);
    _clientCreationTimes[client] = DateTime.now();
    _activeDownloadsPerClient[client] = {};
    if (host.isNotEmpty) {
      _clientHosts[client] = host;
    }

    return client;
  }

  /// Reconfigures [client]'s underlying dart:io [HttpClient] to route through
  /// the configured HTTP proxy, preserving the debug-certificate override that
  /// [buildTransferDio] installs. No-op unless an HTTP proxy is fully
  /// configured (SOCKS5 is not supported on the dart HTTP path).
  void _applyProxy(Dio client, String? url) {
    final policy = DioNetworkPolicy.instance;
    if (!policy.httpProxyActive) return;
    final adapter = client.httpClientAdapter;
    if (adapter is! IOHttpClientAdapter) return;
    final host = policy.proxyHost;
    final port = policy.proxyPort;
    final user = policy.proxyUsername;
    final pass = policy.proxyPassword;
    adapter.validateCertificate = null;
    adapter.createHttpClient = () {
      final httpClient = HttpClient();
      httpClient.badCertificateCallback = DebugCertOverride.getCallback(url);
      httpClient.findProxy = (_) => 'PROXY $host:$port';
      if (user != null && user.isNotEmpty) {
        httpClient.addProxyCredentials(
          host,
          port,
          '',
          HttpClientBasicCredentials(user, pass ?? ''),
        );
      }
      return httpClient;
    };
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
