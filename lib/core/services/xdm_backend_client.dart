import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../features/settings/provider/settings_provider.dart';
import 'backend_health_service.dart';
import 'circuit_breaker.dart';
import 'diagnostic_service.dart';
import 'logging_service.dart';
import 'retry_engine.dart';
import 'xdm_backend_exceptions.dart';

final _log = LoggingService.logger('XdmBackendClient');

class XdmBackendClient {
  static final XdmBackendClient _instance = XdmBackendClient._internal();
  factory XdmBackendClient() => _instance;

  static String? _apiKey;

  late Dio _dio;
  // FIX-H5: Dio instance pool (max 3)
  static const int _maxPoolSize = 3;
  final List<Dio> _availablePool = [];
  final Set<Dio> _allPoolInstances = {};

  Dio _acquireDio(String baseUrl) {
    Dio dio;
    if (_availablePool.isNotEmpty) {
      dio = _availablePool.removeLast();
      dio.options.baseUrl = baseUrl;
    } else if (_allPoolInstances.length < _maxPoolSize) {
      dio = Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
        headers: {
          'Accept': 'application/json',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        },
      ));
      _configureDioSSL(dio);
      _allPoolInstances.add(dio);
    } else {
      dio = _allPoolInstances.first;
      dio.options.baseUrl = baseUrl;
    }
    return dio;
  }

  void _releaseDio(Dio? dio) {
    if (dio != null &&
        _allPoolInstances.contains(dio) &&
        !_availablePool.contains(dio)) {
      _availablePool.add(dio);
    }
  }

  /// Closes all pooled Dio instances and the main instance
  void dispose() {
    for (final dio in _allPoolInstances) {
      dio.close(force: true);
    }
    _allPoolInstances.clear();
    _availablePool.clear();
    _dio.close(force: true);
  }

  final Map<String, _StreamsCacheEntry> _streamsCache = {};
  final _ApiRateLimiter _rateLimiter = _ApiRateLimiter();

  /// ERR-RESILIENCE-2.2: One circuit breaker per backend URL so a sick backend
  /// stops receiving requests (and stops failing over to it) until it recovers.
  final Map<String, CircuitBreaker> _backendCircuits = {};

  static const _secureStorage = FlutterSecureStorage();
  static const _apiKeyStorageKey = 'xdm_backend_api_key';

  /// Reads the API key from secure storage or compile-time env var.
  static Future<void> loadApiKey() async {
    try {
      final stored = await _secureStorage.read(key: _apiKeyStorageKey);

      if (stored != null && stored.isNotEmpty) {
        _apiKey = stored;
        _log.info('API key loaded from secure storage');
        return;
      }

      const envKey = String.fromEnvironment('DMX_API_KEY');

      if (envKey.isNotEmpty) {
        _apiKey = envKey;
        _log.info('API key loaded from compile-time define');
        return;
      }

      _apiKey = null;
    } catch (e) {
      _log.warning('Failed to load API key', e);
      _apiKey = null;
    }
  }

  /// Returns the effective API key.
  String get _effectiveApiKey {
    final key = _apiKey;

    if (key != null && key.isNotEmpty) {
      return key;
    }

    try {
      final customToken = SettingsProvider.instance.backendToken;
      if (customToken.isNotEmpty) {
        return customToken;
      }
    } catch (_) {}

    return '';
  }

  /// Persists a new API key to secure storage and refreshes the Dio client.
  static Future<void> setApiKey(String key) async {
    if (key.isEmpty) {
      await _secureStorage.delete(key: _apiKeyStorageKey);
      _apiKey = null;
    } else {
      await _secureStorage.write(key: _apiKeyStorageKey, value: key);
      _apiKey = key;
    }
    _instance._updateDioFromSettings();
  }

  XdmBackendClient._internal() {
    _updateDioFromSettings();
  }

  /// Updates the backend configuration from SettingsProvider
  void _updateDioFromSettings() {
    for (final client in _allPoolInstances) {
      client.close(force: true);
    }
    _allPoolInstances.clear();
    _availablePool.clear();

    String baseUrl;
    try {
      final settings = SettingsProvider.instance;
      baseUrl = settings.backendUrl.isNotEmpty
          ? settings.backendUrl
          : BackendHealthService.instance.activeBaseUrl;
    } catch (e) {
      baseUrl = BackendHealthService.instance.activeBaseUrl;
      _log.fine('Settings not available, using health-service URL: $e');
    }

    // SEC-1: Force HTTPS for non-local backend communication
    final parsedUri = Uri.tryParse(baseUrl);
    final isLocalhost = parsedUri != null &&
        (parsedUri.host == '127.0.0.1' || parsedUri.host == 'localhost');
    if (baseUrl.startsWith('http://') && !isLocalhost) {
      _log.severe('HTTP backend URL rejected. HTTPS is required.');
      baseUrl = baseUrl.replaceFirst('http://', 'https://');
    }

    // Ensure baseUrl doesn't end with / to avoid double slashes with /api
    if (baseUrl.endsWith('/')) {
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    }

    _dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
      headers: {
        'Accept': 'application/json, text/plain, */*',
        // FIX(UA): Use a consistent Android-based User-Agent that matches NewPipe for better compatibility
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
        'Accept-Language': 'en-US,en;q=0.9',
        'X-Requested-With': 'com.xdm.downloadmanager',
        'Referer': 'https://www.youtube.com/',
      },
    ));
    _configureDioSSL(_dio);
    _log.fine('Configured with backend URL: $baseUrl');
  }

  /// Manually updates the backend configuration and refreshes the Dio client
  Future<void> updateBackendConfig(String backendUrl) async {
    await SettingsProvider.instance.setBackendUrl(backendUrl);
    _updateDioFromSettings();
  }

  /// Refreshes the backend configuration from SettingsProvider
  void refreshConfig() {
    _updateDioFromSettings();
  }

  /// Get the current backend URL for UI display
  static String get currentBackendUrl => SettingsProvider.instance.backendUrl;

  // FIX-2: Increase timeout from 30s to 45s for Cloud Run cold starts
  Future<T> _withTimeout<T>(
    Future<T> future, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    try {
      return await future.timeout(timeout);
    } on TimeoutException {
      throw XdmBackendTimeoutException(
        'Request timed out after ${timeout.inSeconds}s',
      );
    }
  }

  Future<Map<String, dynamic>> health() async {
    final authHeader = _buildHeaders();
    try {
      final response = await _withTimeout(
        _dio.get<Map<String, dynamic>>(
          '/health',
          options: Options(headers: authHeader),
        ),
      );
      final data = response.data ?? {};
      BackendHealthService.instance.markHealthy(_dio.options.baseUrl);
      return data;
    } catch (e) {
      throw _handleDioError(e);
    }
  }

  /// Builds per-request headers, injecting the Authorization token.
  /// Throws [BackendUnauthorizedException] if no API key is configured.
  Map<String, String> _buildHeaders([Map<String, String>? extra]) {
    return {
      'Accept': 'application/json',
      'Authorization': 'Bearer $_effectiveApiKey',
      ...?extra,
    };
  }

  List<String> _resolveCandidateBackendUrls() {
    final settings = SettingsProvider.instance;
    final List<String> backendUrls = [];
    if (settings.backendUrl.isNotEmpty) {
      backendUrls.add(settings.backendUrl);
    }
    final parsed = Uri.tryParse(settings.backendUrl);
    final isLocal = parsed != null &&
        (parsed.host == '127.0.0.1' || parsed.host == 'localhost');
    if (!isLocal) {
      backendUrls.addAll(
          BackendHealthService.instance.activeBackends.map((b) => b.baseUrl));
    }
    return backendUrls.toSet().toList();
  }

  /// Fetches downloadable streams for a YouTube video URL.
  ///
  /// [cookies] — Netscape-format or key=value cookie string forwarded as
  ///   `X-YouTube-Cookies`. The backend may also pick from its own cookie pool
  static int cacheHits = 0;
  static int cacheMisses = 0;

  ///   if none are supplied.
  Future<Map<String, dynamic>> getStreams(
    String url, {
    String? cookies,
    String? oauthToken,
    bool forceRefresh = false,
  }) async {
    final cacheKey = _normalizeCacheUrl(url);
    if (!forceRefresh) {
      final cached = _streamsCache[cacheKey];
      if (cached != null) {
        if (!cached.isExpired) {
          // FIX P1-18: Also evict if any googlevideo URL's expire= is within 5m.
          // Previously a cached 10m entry could return a URL expiring in 30s -> 403.
          try {
            final jsonStr = jsonEncode(cached.data);
            final matches = RegExp(r'expire=(\d+)').allMatches(jsonStr);
            bool nearExpiry = false;
            final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            for (final m in matches) {
              final exp = int.tryParse(m.group(1) ?? '');
              if (exp != null && exp - nowSec < 300) {
                nearExpiry = true;
                break;
              }
            }
            if (nearExpiry) {
              _streamsCache.remove(cacheKey);
            } else {
              cached.lastAccessed = DateTime.now();
              cacheHits++;
              return cached.data;
            }
          } catch (_) {
            cached.lastAccessed = DateTime.now();
            cacheHits++;
            return cached.data;
          }
        } else {
          _streamsCache.remove(cacheKey);
        }
      }
    }
    cacheMisses++;

    return _rateLimiter.call('streams', () async {
      final encodedCookies = cookies != null && cookies.isNotEmpty
          ? base64Encode(utf8.encode(cookies))
          : null;
      final headers = _buildHeaders({
        if (encodedCookies != null) ...{
          'X-Cookies': encodedCookies,
          'X-YouTube-Cookies': encodedCookies,
        },
        if (oauthToken != null && oauthToken.isNotEmpty)
          'X-YouTube-OAuth': oauthToken,
      });

      final uniqueBackends = _resolveCandidateBackendUrls();

      Object? lastError;
      var sawNetworkFailure = false;

      for (var baseUrl in uniqueBackends) {
        if (baseUrl.endsWith('/')) {
          baseUrl = baseUrl.substring(0, baseUrl.length - 1);
        }

        // ERR-RESILIENCE-2.2: Skip backends whose circuit is open.
        final circuit = _backendCircuits.putIfAbsent(
          baseUrl,
          () => CircuitBreaker(failureThreshold: 3),
        );
        if (!circuit.allowRequest()) {
          _log.warning(
              'Circuit open for backend $baseUrl, skipping until recovery.');
          sawNetworkFailure = true;
          continue;
        }

        // Try multiple endpoint variations for robustness
        final endpoints = ['/api/streams', '/streams'];

        for (final endpoint in endpoints) {
          Dio? dio;
          try {
            // FIX-H5: Acquire from Dio pool
            dio = _acquireDio(baseUrl);

            final response = await _withTimeout(
              dio.get<Map<String, dynamic>>(
                endpoint,
                queryParameters: {'url': url},
                options: Options(headers: headers),
              ),
            );

            final data = response.data ?? {};
            // Basic validation that it's a valid response
            if (data.containsKey('streams') ||
                data.containsKey('formats') ||
                data.containsKey('url')) {
              BackendHealthService.instance.markHealthy(baseUrl);
              circuit.recordSuccess();

              _evictExpiredStreamsCache();
              _streamsCache[cacheKey] = _StreamsCacheEntry(
                data: data,
                expiry: DateTime.now().add(const Duration(minutes: 10)),
              );
              return data;
            } else {
              _log.warning(
                  'Backend $baseUrl endpoint $endpoint returned invalid data: $data');
              circuit.recordFailure();
              lastError = Exception('Invalid response format');
              continue;
            }
          } catch (e) {
            lastError = e;
            _log.warning('Backend $baseUrl endpoint $endpoint failed: $e');
            circuit.recordFailure();

            if (e is DioException) {
              final statusCode = e.response?.statusCode;
              if (statusCode == 404) {
                // Try next endpoint on the same backend
                continue;
              }
              if (statusCode != null && statusCode >= 400 && statusCode < 500) {
                if (statusCode == 451 || statusCode == 400) {
                  throw _handleDioError(e, baseUrl);
                }
              } else {
                BackendHealthService.instance.markUnhealthy(baseUrl);
                sawNetworkFailure = true;
              }
              if (e.type == DioExceptionType.connectionTimeout ||
                  e.type == DioExceptionType.receiveTimeout ||
                  e.type == DioExceptionType.sendTimeout ||
                  e.type == DioExceptionType.connectionError) {
                sawNetworkFailure = true;
              }
            } else {
              BackendHealthService.instance.markUnhealthy(baseUrl);
              sawNetworkFailure = true;
            }
            // Move to next endpoint or backend
          } finally {
            // FIX-H5: Release to Dio pool
            _releaseDio(dio);
          }
        }
      }
      throw _handleDioError(
        lastError ?? Exception('All backends failed'),
        uniqueBackends.isNotEmpty ? uniqueBackends.first : null,
        sawNetworkFailure,
      );
    });
  }

  /// Fetches playlist metadata and video list for a YouTube playlist URL.
  ///
  /// [cookies] — forwarded as `X-YouTube-Cookies`.
  Future<Map<String, dynamic>> getPlaylist(
    String url, {
    String? cookies,
    dynamic pageToken,
    int? pageSize,
  }) async {
    return _rateLimiter.call('playlist', () async {
      final encodedCookies = cookies != null && cookies.isNotEmpty
          ? base64Encode(utf8.encode(cookies))
          : null;
      final headers = _buildHeaders({
        if (encodedCookies != null) ...{
          'X-Cookies': encodedCookies,
          'X-YouTube-Cookies': encodedCookies,
        },
      });

      final uniqueBackends = _resolveCandidateBackendUrls();

      Object? lastError;

      for (var baseUrl in uniqueBackends) {
        if (baseUrl.endsWith('/')) {
          baseUrl = baseUrl.substring(0, baseUrl.length - 1);
        }

        // ERR-RESILIENCE-2.2: Skip backends whose circuit is open.
        final circuit = _backendCircuits.putIfAbsent(
          baseUrl,
          () => CircuitBreaker(failureThreshold: 3),
        );
        if (!circuit.allowRequest()) {
          _log.warning(
              'Circuit open for backend $baseUrl, skipping until recovery.');
          continue;
        }

        final endpoints = ['/api/playlist', '/playlist'];

        for (final endpoint in endpoints) {
          Dio? dio;
          try {
            // FIX-H5: Acquire from Dio pool
            dio = _acquireDio(baseUrl);
            final response = await _withTimeout(
              dio.get<Map<String, dynamic>>(
                endpoint,
                queryParameters: {
                  'url': url,
                  if (pageToken != null) 'pageToken': pageToken.toString(),
                  if (pageSize != null) 'pageSize': pageSize,
                },
                options: Options(headers: headers),
              ),
            );
            final data = response.data ?? {};
            BackendHealthService.instance.markHealthy(baseUrl);
            circuit.recordSuccess();
            return data;
          } catch (e) {
            lastError = e;
            _log.warning(
                'Backend $baseUrl endpoint $endpoint failed for playlist: $e');
            circuit.recordFailure();
            if (e is DioException) {
              final statusCode = e.response?.statusCode;
              if (statusCode == 404) continue;
              if (statusCode != null && statusCode >= 400 && statusCode < 500) {
                if (statusCode == 401) {
                  throw _handleDioError(e, baseUrl);
                }
              } else {
                BackendHealthService.instance.markUnhealthy(baseUrl);
              }
            } else {
              BackendHealthService.instance.markUnhealthy(baseUrl);
            }
          } finally {
            // FIX-H5: Release to Dio pool
            _releaseDio(dio);
          }
        }
      }
      throw _handleDioError(lastError ?? Exception('All backends failed'),
          uniqueBackends.isNotEmpty ? uniqueBackends.first : null);
    });
  }

  Future<List<Map<String, dynamic>>> search(String q) async {
    return _rateLimiter.call('search', () async {
      final headers = _buildHeaders();

      final uniqueBackends = _resolveCandidateBackendUrls();

      Object? lastError;

      for (var baseUrl in uniqueBackends) {
        if (baseUrl.endsWith('/')) {
          baseUrl = baseUrl.substring(0, baseUrl.length - 1);
        }

        final endpoints = ['/api/search', '/search'];

        for (final endpoint in endpoints) {
          Dio? dio;
          try {
            // FIX-H5: Acquire from Dio pool
            dio = _acquireDio(baseUrl);
            final response = await _withTimeout(
              dio.get<Map<String, dynamic>>(
                endpoint,
                queryParameters: {'q': q},
                options: Options(headers: headers),
              ),
            );
            final data = response.data ?? {};
            BackendHealthService.instance.markHealthy(baseUrl);
            final results = data['results'] as List?;
            if (results == null) return [];
            return results
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
          } catch (e) {
            lastError = e;
            _log.warning(
                'Backend $baseUrl endpoint $endpoint failed for search: $e');
            if (e is DioException) {
              if (e.response?.statusCode == 404) continue;
              if (e.response?.statusCode != null &&
                  e.response!.statusCode! >= 500) {
                BackendHealthService.instance.markUnhealthy(baseUrl);
              }
            } else {
              BackendHealthService.instance.markUnhealthy(baseUrl);
            }
          } finally {
            // FIX-H5: Release to Dio pool
            _releaseDio(dio);
          }
        }
      }
      throw _handleDioError(lastError ?? Exception('All backends failed'),
          uniqueBackends.isNotEmpty ? uniqueBackends.first : null);
    });
  }

  BackendException _handleDioError(Object error,
      [String? failingUrl, bool sawNetworkFailure = false]) {
    final ex = _buildBackendException(error, failingUrl, sawNetworkFailure);
    // OBS (Plan 06.1): Route every terminal media-backend failure through
    // DiagnosticService so extraction outages are observable in the support
    // screen instead of failing opaquely. Callers still receive the same typed
    // BackendException, so no call site changes are required.
    _recordBackendFailure(ex, failingUrl ?? _dio.options.baseUrl);
    return ex;
  }

  /// Records a media-backend failure to diagnostics for observability. Never
  /// throws — telemetry must not break the request path.
  void _recordBackendFailure(BackendException ex, String backendUrl) {
    try {
      DiagnosticService.instance.record(
        'media',
        'Backend request failed: ${ex.runtimeType}',
        error: ex,
        details: 'backend=$backendUrl message=${ex.message}',
      );
    } catch (e) {
      _log.fine('Failed to record backend failure to diagnostics: $e');
    }
  }

  BackendException _buildBackendException(
      Object error, String? failingUrl, bool sawNetworkFailure) {
    if (error is BackendException) return error;

    // When the failover chain saw any network/server failure, prefer a
    // network exception over a later 4xx (e.g. a fallback backend's 404).
    // Network failures are transient (retryable, trigger local fallback);
    // a "not found" would otherwise suppress the retry entirely.
    if (sawNetworkFailure) {
      return const BackendNetworkException(
        'Cannot reach download backend. Check your connection.',
      );
    }

    final targetUrl = failingUrl ?? _dio.options.baseUrl;

    if (error is TimeoutException) {
      BackendHealthService.instance.markUnhealthy(targetUrl);
      if (failingUrl == null || failingUrl == _dio.options.baseUrl) {
        _updateDioFromSettings();
      }
      return const XdmBackendTimeoutException('Request timed out.');
    }

    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      final responseData = error.response?.data;
      String? backendMsg;
      if (responseData != null) {
        if (responseData is Map) {
          backendMsg = (responseData['detail'] ??
                  responseData['message'] ??
                  responseData['error'] ??
                  responseData['msg'])
              ?.toString();
        } else if (responseData is String) {
          backendMsg = responseData;
          try {
            final decoded = jsonDecode(responseData);
            if (decoded is Map) {
              backendMsg = (decoded['detail'] ??
                      decoded['message'] ??
                      decoded['error'] ??
                      decoded['msg'])
                  ?.toString();
            }
          } catch (e, st) {
            LoggingService.logger('XdmBackendClient')
                .warning('Operation failed', e, st);
          }
        } else {
          backendMsg = responseData.toString();
        }
      }

      if (statusCode == 400) {
        return BackendBadRequestException(
          backendMsg ?? 'Invalid request or unsupported URL.',
        );
      } else if (statusCode == 401 || statusCode == 403) {
        return BackendUnauthorizedException(
          backendMsg ?? 'Backend authentication failed. Check your API token.',
        );
      } else if (statusCode == 404) {
        return const BackendNotFoundException();
      } else if (statusCode == 429) {
        int? retryAfter;
        final retryHeader = error.response?.headers.value('retry-after');
        if (retryHeader != null) {
          retryAfter = int.tryParse(retryHeader);
        }
        return BackendRateLimitException(
          retryAfterSeconds: retryAfter,
          message: backendMsg,
        );
      } else if (statusCode == 451) {
        return BackendBadRequestException(
          backendMsg ??
              'Video is geo-restricted and not available from this server.',
        );
      } else if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.badCertificate ||
          (statusCode != null && statusCode >= 500)) {
        BackendHealthService.instance.markUnhealthy(targetUrl);
        if (failingUrl == null || failingUrl == _dio.options.baseUrl) {
          _updateDioFromSettings();
        }

        final rawMsg = error.message ?? '';
        final isRawSocketError = rawMsg.contains('Connection closed') ||
            rawMsg.contains('Connection errored') ||
            rawMsg.contains('SocketException') ||
            rawMsg.contains('full header');
        final cleanMsg = (backendMsg != null && backendMsg.isNotEmpty)
            ? backendMsg
            : (isRawSocketError || rawMsg.isEmpty
                ? 'Cannot reach download backend. Check your connection.'
                : rawMsg);
        return BackendNetworkException(cleanMsg);
      }
      return BackendUnknownException(
        backendMsg ?? error.message ?? 'Unexpected backend error.',
      );
    }

    return BackendUnknownException(error.toString());
  }

  static const String pinnedBackendHost =
      'xdm-backend-10763667121.europe-west1.run.app';
  static const Set<String> _pinnedSpkiFingerprints = {
    // GTS Root R1 & GTS CA 1C3 SPKI sha256 digests
    'f252e08d6614e25e50868b9f65ee9da54eee4d0f10056dcd5e2f640f6d2f70e8',
    '81177651a2d677a29e2f5b66d8f8d08643801f945391d4e7ef6a7d1894b9f298',
  };

  // FIX-0.1: Remove user-reachable SSL bypass; release builds enforce strict certificate validation
  void _configureDioSSL(Dio client) {
    try {
      if (client.httpClientAdapter is IOHttpClientAdapter) {
        final adapter = client.httpClientAdapter as IOHttpClientAdapter;
        adapter.validateCertificate = (cert, host, port) {
          final normalizedHost = host.toLowerCase();
          if (normalizedHost == 'localhost' ||
              normalizedHost == '127.0.0.1' ||
              normalizedHost.startsWith('127.') ||
              normalizedHost == '::1') {
            return true;
          }
          if (cert == null) return false;
          if (normalizedHost == pinnedBackendHost ||
              normalizedHost.endsWith('.run.app')) {
            final sha256Fingerprint =
                sha256.convert(cert.der).toString().toLowerCase();
            if (_pinnedSpkiFingerprints.isNotEmpty) {
              return _pinnedSpkiFingerprints.contains(sha256Fingerprint);
            }
          }
          return true;
        };
        adapter.createHttpClient = () {
          final httpClient = HttpClient();
          httpClient.badCertificateCallback = (cert, host, port) {
            final h = host.toLowerCase();
            if (h == 'localhost' || h == '127.0.0.1') {
              return true;
            }
            // PRODUCTION: reject ALL external self-signed certificates unconditionally.
            return false;
          };
          return httpClient;
        };
      }
    } catch (e) {
      _log.warning('Failed to configure SSL for Dio: $e');
    }
  }

  static String _normalizeCacheUrl(String rawUrl) {
    try {
      final uri = Uri.parse(rawUrl.trim());
      final queryParams = Map<String, String>.from(uri.queryParameters);
      queryParams.removeWhere((key, _) =>
          key == 'hl' ||
          key == 'gl' ||
          key == 'feature' ||
          key == 'si' ||
          key.startsWith('utm_'));
      return uri
          .replace(queryParameters: queryParams.isEmpty ? null : queryParams)
          .toString();
    } catch (_) {
      return rawUrl.trim();
    }
  }

  void _evictExpiredStreamsCache() {
    _streamsCache.removeWhere((_, entry) => entry.isExpired);
    while (_streamsCache.length >= 50) {
      final lru = _streamsCache.entries.reduce(
        (a, b) => a.value.lastAccessed.isBefore(b.value.lastAccessed) ? a : b,
      );
      _streamsCache.remove(lru.key);
    }
  }
}

class _StreamsCacheEntry {
  final Map<String, dynamic> data;
  final DateTime expiry;
  DateTime lastAccessed;

  _StreamsCacheEntry({
    required this.data,
    required this.expiry,
  }) : lastAccessed = DateTime.now();

  bool get isExpired => DateTime.now().isAfter(expiry);
}

class _ApiRateLimiter {
  // NOTE: This rate limiter is intentionally in-memory only. The sliding window
  // resets every time the app restarts, which means a burst of requests made
  // just before a restart can exceed the effective per-session quota. For the
  // current call volumes (playlist/stream lookups triggered by user action)
  // this is an acceptable trade-off. If persistent cross-session rate limiting
  // becomes necessary, persist _endpoints timestamps to SharedPreferences.
  final Map<String, List<DateTime>> _endpoints = {};
  final Map<String, int> _limits = {
    'streams': 30,
    'playlist': 10,
    'search': 10,
  };

  Future<T> call<T>(String endpoint, Future<T> Function() request) async {
    final key = endpoint.split('/').last;
    final limit = _limits[key] ?? 30;
    final now = DateTime.now();

    _endpoints.putIfAbsent(key, () => []);
    _endpoints[key]!.removeWhere((t) => now.difference(t).inSeconds >= 60);

    if (_endpoints[key]!.length >= limit) {
      final retryAfter = max(
        1,
        60 - now.difference(_endpoints[key]!.first).inSeconds,
      );
      throw BackendRateLimitException(
        retryAfterSeconds: retryAfter,
        message: 'Rate limit exceeded for endpoint: $endpoint',
      );
    }

    _endpoints[key]!.add(now);

    // ERR-RESILIENCE-2.1: Wrap every backend API request in the centralized
    // retry engine. The inner request already fails over across backends and
    // endpoints; the engine adds exponential backoff for transient failures
    // (network / timeout / 5xx / 429) without duplicating the failover logic.
    final engine = RetryEngine(
      maxRetries: 2,
      baseDelay: const Duration(seconds: 2),
      backoffMultiplier: 2.0,
      maxDelay: const Duration(seconds: 15),
    );
    return engine.execute(
      request,
      onRetry: (error, attempt, delay) {
        _log.warning('Backend $endpoint attempt $attempt failed ($error); '
            'retrying in ${delay.inMilliseconds}ms');
      },
    );
  }
}
