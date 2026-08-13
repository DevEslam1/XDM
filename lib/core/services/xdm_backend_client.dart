import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../features/settings/provider/settings_provider.dart';
import 'backend_health_service.dart';
import 'circuit_breaker.dart';
import 'logging_service.dart';
import 'retry_engine.dart';
import 'xdm_backend_exceptions.dart';

final _log = LoggingService.logger('XdmBackendClient');

class XdmBackendClient {
  static final XdmBackendClient _instance = XdmBackendClient._internal();
  factory XdmBackendClient() => _instance;

  // P0-1: No hardcoded fallback secret
  static String? _apiKey;

  late Dio _dio;
  final Map<String, _StreamsCacheEntry> _streamsCache = {};
  final _ApiRateLimiter _rateLimiter = _ApiRateLimiter();

  /// ERR-RESILIENCE-2.2: One circuit breaker per backend URL so a sick backend
  /// stops receiving requests (and stops failing over to it) until it recovers.
  final Map<String, CircuitBreaker> _backendCircuits = {};

  static final _secureStorage = const FlutterSecureStorage();
  static const _apiKeyStorageKey = 'xdm_backend_api_key';

  /// Reads the API key from secure storage or compile-time env var.
  static Future<void> loadApiKey() async {
    try {
      final stored = await _secureStorage.read(key: _apiKeyStorageKey);

      if (stored != null && stored.isNotEmpty) {
        _apiKey = stored;
        _log.info('P0-1: API key loaded from secure storage');
        return;
      }

      const envKey = String.fromEnvironment('DMX_API_KEY');

      if (envKey.isNotEmpty) {
        _apiKey = envKey;
        _log.info('P0-1: API key loaded from compile-time define');
        return;
      }

      _apiKey = null;
      _log.warning('P0-1: No API key configured');
    } catch (e) {
      _log.severe('P0-1: Failed to load API key', e);
      _apiKey = null;
    }
  }

  /// Returns the effective API key.
  String get _effectiveApiKey {
    final key = _apiKey;

    if (key == null || key.isEmpty) {
      throw const BackendUnauthorizedException('No API key configured');
    }

    return key;
  }

  /// Persists a new API key to secure storage and refreshes the Dio client.
  /// Pass an empty string to clear the stored key; subsequent calls will then
  /// require a key via [DMX_API_KEY] env var or a later [loadApiKey] call.
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
        'X-Requested-With': 'com.example.dmx',
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
  }) async {
    final cached = _streamsCache[url];
    if (cached != null) {
      if (!cached.isExpired) {
        cached.lastAccessed = DateTime.now();
        // Validate stream reachability with HEAD request (5s timeout)
        String? testStreamUrl;
        try {
          final streams = cached.data['streams'] as List<dynamic>?;
          if (streams != null && streams.isNotEmpty) {
            // ignore: avoid_dynamic_calls
            testStreamUrl = streams.first['url'] as String?;
          }
        } catch (_) {}

        bool valid = true;
        if (testStreamUrl != null && testStreamUrl.isNotEmpty) {
          try {
            final headRes = await Dio().head(
              testStreamUrl,
              options: Options(
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 5),
                validateStatus: (s) => true,
              ),
            );
            if (headRes.statusCode == 403 || headRes.statusCode == 410) {
              _log.info(
                  'Cached stream URL returned ${headRes.statusCode}, evicting cache for $url');
              _streamsCache.remove(url);
              valid = false;
            }
          } catch (_) {
            // Best effort validation
          }
        }

        if (valid) {
          cacheHits++;
          return cached.data;
        }
      } else {
        _streamsCache.remove(url);
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

      // FIX-1: Try each healthy backend in priority order, prioritizing user setting
      final settings = SettingsProvider.instance;
      final List<String> backendUrls = [];
      if (settings.backendUrl.isNotEmpty) {
        backendUrls.add(settings.backendUrl);
      }
      backendUrls.addAll(
          BackendHealthService.instance.activeBackends.map((b) => b.baseUrl));
      final uniqueBackends = backendUrls.toSet().toList();

      Object? lastError;
      // When ANY backend failed with a network/server error (timeout, refused,
      // 5xx), surface that instead of the last 404 the failover chain saw. A
      // 404 from a fallback backend must not mask the real "backend
      // unreachable" condition that should trigger retry + local fallback.
      var sawNetworkFailure = false;

      for (var baseUrl in uniqueBackends) {
        if (baseUrl.endsWith('/')) {
          baseUrl = baseUrl.substring(0, baseUrl.length - 1);
        }

        // ERR-RESILIENCE-2.2: Skip backends whose circuit is open. A probe is
        // allowed after openTimeout; a failed probe re-opens the circuit.
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
          // C3: hoisted so the finally clause can close the throwaway client.
          Dio? dio;
          try {
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
              _streamsCache[url] = _StreamsCacheEntry(
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
            // C3: this throwaway-per-backend/endpoint Dio must be closed so
            // its connection pool doesn't leak sockets during playlist batch
            // enqueues (50+ videos).
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
            dio?.close(
                force: true); // C3: close the throwaway Dio's connection pool
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

      // Try each healthy backend in priority order, prioritizing user setting
      final settings = SettingsProvider.instance;
      final List<String> backendUrls = [];
      if (settings.backendUrl.isNotEmpty) {
        backendUrls.add(settings.backendUrl);
      }
      backendUrls.addAll(
          BackendHealthService.instance.activeBackends.map((b) => b.baseUrl));
      final uniqueBackends = backendUrls.toSet().toList();

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
          // C3: hoisted so the finally clause can close the throwaway client.
          Dio? dio;
          try {
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
            // C3: close the throwaway Dio's connection pool.
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
            dio?.close(
                force: true); // C3: close the throwaway Dio's connection pool
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

      // Try each healthy backend in priority order, prioritizing user setting
      final settings = SettingsProvider.instance;
      final List<String> backendUrls = [];
      if (settings.backendUrl.isNotEmpty) {
        backendUrls.add(settings.backendUrl);
      }
      backendUrls.addAll(
          BackendHealthService.instance.activeBackends.map((b) => b.baseUrl));
      final uniqueBackends = backendUrls.toSet().toList();

      Object? lastError;

      for (var baseUrl in uniqueBackends) {
        if (baseUrl.endsWith('/')) {
          baseUrl = baseUrl.substring(0, baseUrl.length - 1);
        }

        final endpoints = ['/api/search', '/search'];

        for (final endpoint in endpoints) {
          // C3: hoisted so the finally clause can close the throwaway client.
          Dio? dio;
          try {
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
            // C3: close the throwaway Dio's connection pool.
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
            dio?.close(
                force: true); // C3: close the throwaway Dio's connection pool
          }
        }
      }
      throw _handleDioError(lastError ?? Exception('All backends failed'),
          uniqueBackends.isNotEmpty ? uniqueBackends.first : null);
    });
  }

  BackendException _handleDioError(Object error,
      [String? failingUrl, bool sawNetworkFailure = false]) {
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
          } catch (_) {}
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

  void _configureDioSSL(Dio client) {
    try {
      final bypassSSL = SettingsProvider.instance.bypassSSL;
      if (kDebugMode &&
          bypassSSL &&
          client.httpClientAdapter is IOHttpClientAdapter) {
        assert(kDebugMode, 'SSL bypass cannot activate in release builds');
        final adapter = client.httpClientAdapter as IOHttpClientAdapter;
        adapter.createHttpClient = () {
          final httpClient = HttpClient();
          httpClient.badCertificateCallback = (cert, host, port) => true;
          return httpClient;
        };
      }
    } catch (e) {
      _log.warning('Failed to configure SSL bypass for Dio: $e');
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
