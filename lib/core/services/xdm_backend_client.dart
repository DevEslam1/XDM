import 'dart:async';
import 'dart:convert';
import 'dart:math' show max;

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/constants.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'backend_health_service.dart';
import 'logging_service.dart';
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

  static final _secureStorage = const FlutterSecureStorage();
  static const _apiKeyStorageKey = 'xdm_backend_api_key';

  /// // P0-1: Reads the API key from secure storage or compile-time env var.
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

      _apiKey = kDefaultApiKey;
      _log.info('P0-1: Using default API key');
    } catch (e) {
      _log.severe('P0-1: Failed to load API key', e);
      _apiKey = kDefaultApiKey;
    }
  }

  /// Returns the effective API key.
  String get _effectiveApiKey {
    final key = _apiKey;

    if (key == null || key.isEmpty) {
      return kDefaultApiKey;
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
  // FIX-1: Wire BackendHealthService activeBaseUrl & timeouts in _updateDioFromSettings
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
    // Do NOT force-close old _dio
    _dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 25),
      receiveTimeout: const Duration(seconds: 60),
      headers: const {'Accept': 'application/json'},
    ));
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
  ///   if none are supplied.
  Future<Map<String, dynamic>> getStreams(
    String url, {
    String? cookies,
    String? oauthToken,
  }) async {
    final cached = _streamsCache[url];
    if (cached != null) {
      if (!cached.isExpired) {
        return cached.data;
      } else {
        _streamsCache.remove(url);
      }
    }

    return _rateLimiter.call('streams', () async {
      final headers = _buildHeaders({
        if (cookies != null && cookies.isNotEmpty) ...{
          'X-Cookies': base64Encode(utf8.encode(cookies)),
          'X-YouTube-Cookies': base64Encode(utf8.encode(cookies)),
        },
        // FIX-08: Forward OAuth token if available
        if (oauthToken != null && oauthToken.isNotEmpty)
          'X-YouTube-OAuth': oauthToken,
      });

      // FIX-1: Try each healthy backend in priority order
      final backends = BackendHealthService.instance.activeBackends;
      Object? firstError;
      Object? lastError;

      for (final backend in backends) {
        try {
          final dio = Dio(BaseOptions(
            baseUrl: backend.baseUrl,
            connectTimeout: const Duration(seconds: 25),
            receiveTimeout: const Duration(seconds: 60),
            headers: const {'Accept': 'application/json'},
          ));
          final response = await _withTimeout(
            dio.get<Map<String, dynamic>>(
              '/api/streams',
              queryParameters: {'url': url},
              options: Options(headers: headers),
            ),
          );
          final data = response.data ?? {};
          BackendHealthService.instance.markHealthy(backend.baseUrl);

          _streamsCache.removeWhere((key, val) => val.isExpired);
          if (_streamsCache.length >= 50) {
            final oldestKey = _streamsCache.entries
                .reduce((a, b) => a.value.expiry.isBefore(b.value.expiry) ? a : b)
                .key;
            _streamsCache.remove(oldestKey);
          }

          _streamsCache[url] = _StreamsCacheEntry(
            data: data,
            expiry: DateTime.now().add(const Duration(minutes: 10)),
          );
          return data;
        } catch (e) {
          firstError ??= e;
          lastError = e;
          if (e is DioException && e.response?.statusCode != null) {
            final statusCode = e.response!.statusCode!;
            if (statusCode >= 400 && statusCode < 500) {
              BackendHealthService.instance.markHealthy(backend.baseUrl);
              if (statusCode == 400 || statusCode == 401 || statusCode == 404 || statusCode == 451) {
                throw _handleDioError(e);
              }
            } else {
              BackendHealthService.instance.markUnhealthy(backend.baseUrl);
            }
          } else {
            BackendHealthService.instance.markUnhealthy(backend.baseUrl);
          }
          _log.warning('Backend ${backend.baseUrl} failed: $e');
          continue;
        }
      }
      throw _handleDioError(firstError ?? lastError ?? Exception('All backends failed'));
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
      final headers = _buildHeaders({
        if (cookies != null && cookies.isNotEmpty) ...{
          'X-Cookies': base64Encode(utf8.encode(cookies)),
          'X-YouTube-Cookies': base64Encode(utf8.encode(cookies)),
        },
      });

      // FIX-1: Try each healthy backend in priority order
      final backends = BackendHealthService.instance.activeBackends;
      Object? firstError;
      Object? lastError;

      for (final backend in backends) {
        try {
          final dio = Dio(BaseOptions(
            baseUrl: backend.baseUrl,
            connectTimeout: const Duration(seconds: 25),
            receiveTimeout: const Duration(seconds: 60),
            headers: const {'Accept': 'application/json'},
          ));
          final response = await _withTimeout(
            dio.get<Map<String, dynamic>>(
              '/api/playlist',
              queryParameters: {
                'url': url,
                if (pageToken != null) 'pageToken': pageToken.toString(),
                // ignore: use_null_aware_elements — key is non-null; if-guard is correct here
                if (pageSize != null) 'pageSize': pageSize,
              },
              options: Options(headers: headers),
            ),
          );
          final data = response.data ?? {};
          BackendHealthService.instance.markHealthy(backend.baseUrl);
          return data;
        } catch (e) {
          firstError ??= e;
          lastError = e;
          if (e is DioException && e.response?.statusCode != null) {
            final statusCode = e.response!.statusCode!;
            if (statusCode >= 400 && statusCode < 500) {
              BackendHealthService.instance.markHealthy(backend.baseUrl);
              if (statusCode == 400 || statusCode == 401 || statusCode == 404 || statusCode == 451) {
                throw _handleDioError(e);
              }
            } else {
              BackendHealthService.instance.markUnhealthy(backend.baseUrl);
            }
          } else {
            BackendHealthService.instance.markUnhealthy(backend.baseUrl);
          }
          _log.warning('Backend ${backend.baseUrl} failed: $e');
          continue;
        }
      }
      throw _handleDioError(firstError ?? lastError ?? Exception('All backends failed'));
    });
  }

  Future<List<Map<String, dynamic>>> search(String q) async {
    return _rateLimiter.call('search', () async {
      final headers = _buildHeaders();
      // FIX-1: Try each healthy backend in priority order
      final backends = BackendHealthService.instance.activeBackends;
      Object? firstError;
      Object? lastError;

      for (final backend in backends) {
        try {
          final dio = Dio(BaseOptions(
            baseUrl: backend.baseUrl,
            connectTimeout: const Duration(seconds: 25),
            receiveTimeout: const Duration(seconds: 60),
            headers: const {'Accept': 'application/json'},
          ));
          final response = await _withTimeout(
            dio.get<Map<String, dynamic>>(
              '/api/search',
              queryParameters: {'q': q},
              options: Options(headers: headers),
            ),
          );
          final data = response.data ?? {};
          BackendHealthService.instance.markHealthy(backend.baseUrl);
          final results = data['results'] as List?;
          if (results == null) return [];
          return results.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        } catch (e) {
          firstError ??= e;
          lastError = e;
          if (e is DioException && e.response?.statusCode != null) {
            final statusCode = e.response!.statusCode!;
            if (statusCode >= 400 && statusCode < 500) {
              BackendHealthService.instance.markHealthy(backend.baseUrl);
              if (statusCode == 400 || statusCode == 401 || statusCode == 404 || statusCode == 451) {
                throw _handleDioError(e);
              }
            } else {
              BackendHealthService.instance.markUnhealthy(backend.baseUrl);
            }
          } else {
            BackendHealthService.instance.markUnhealthy(backend.baseUrl);
          }
          _log.warning('Backend ${backend.baseUrl} failed: $e');
          continue;
        }
      }
      throw _handleDioError(firstError ?? lastError ?? Exception('All backends failed'));
    });
  }

  BackendException _handleDioError(Object error) {
    if (error is BackendException) return error;
    if (error is TimeoutException) {
      final currentUrl = _dio.options.baseUrl;
      BackendHealthService.instance.markUnhealthy(currentUrl);
      _updateDioFromSettings();
      return const XdmBackendTimeoutException('Request timed out.');
    }

    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      final responseData = error.response?.data;
      String? backendMsg;
      if (responseData is Map && responseData['detail'] != null) {
        backendMsg = responseData['detail'].toString();
      }

      if (statusCode == 400) {
        return BackendBadRequestException(
          backendMsg ?? 'Invalid request or unsupported URL.',
        );
      } else if (statusCode == 401 || statusCode == 403) {
        return const BackendUnauthorizedException();
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
        final currentUrl = _dio.options.baseUrl;
        BackendHealthService.instance.markUnhealthy(currentUrl);
        _updateDioFromSettings();

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
}

class _StreamsCacheEntry {
  final Map<String, dynamic> data;
  final DateTime expiry;

  _StreamsCacheEntry({required this.data, required this.expiry});

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
    return await request();
  }
}
