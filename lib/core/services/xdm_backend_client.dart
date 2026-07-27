import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/constants.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'xdm_backend_exceptions.dart';

// TODO: Add per-device anonymous JWTs issued by Firebase Auth if further backend auth hardening is needed.
// TODO: Inject settings via constructor instead of direct SettingsProvider.instance dependency for testability.

class XdmBackendClient {
  static final XdmBackendClient _instance = XdmBackendClient._internal();
  factory XdmBackendClient() => _instance;

  static String? _apiKey;

  late Dio _dio;
  final Map<String, _StreamsCacheEntry> _streamsCache = {};
  final _ApiRateLimiter _rateLimiter = _ApiRateLimiter();

  static final _secureStorage = const FlutterSecureStorage();
  static const _apiKeyStorageKey = 'xdm_backend_api_key';

  /// Reads the API key from secure storage or from the compile-time
  /// [DMX_API_KEY] environment variable.  No hardcoded production fallback
  /// exists; if neither source provides a key, [_apiKey] is set to null and
  /// any subsequent API call will throw [BackendUnauthorizedException].
  ///
  /// Call this once at app startup before using the client.
  static Future<void> loadApiKey() async {
    try {
      final stored = await _secureStorage.read(key: _apiKeyStorageKey);

      if (stored != null && stored.isNotEmpty) {
        _apiKey = stored;
        return;
      }

      const envKey = String.fromEnvironment('DMX_API_KEY');

      if (envKey.isNotEmpty) {
        _apiKey = envKey;
        return;
      }

      _apiKey = null;
    } catch (e) {
      debugPrint('[XdmBackendClient] Failed to load API key: $e');
      _apiKey = null;
    }
  }

  /// Returns the effective API key, throwing [BackendUnauthorizedException]
  /// when no key has been configured.
  String get _effectiveApiKey {
    final key = _apiKey;

    if (key == null || key.isEmpty) {
      throw const BackendUnauthorizedException(
        'Backend API key is not configured.',
      );
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
    final settings = SettingsProvider.instance;
    try {
      _dio.close(force: true);
    } catch (_) {
      // First initialization, nothing to close
    }

    // Build headers without the key; the key is injected per-request via
    // [_buildHeaders] so that a [BackendUnauthorizedException] is thrown at
    // the call site rather than silently at construction time.
    _dio = Dio(
      BaseOptions(
        baseUrl: settings.backendUrl.isNotEmpty
            ? settings.backendUrl
            : kDefaultBackendBaseUrl,
        connectTimeout: const Duration(seconds: 15),
        // Backend extraction can take up to 45 s; give a comfortable margin.
        receiveTimeout: const Duration(seconds: 60),
        headers: const {
          'Accept': 'application/json',
        },
      ),
    );

    if (kDebugMode) {
      debugPrint(
        '[XdmBackendClient] Configured with backend URL: '
        '${settings.backendUrl.isNotEmpty ? settings.backendUrl : kDefaultBackendBaseUrl}',
      );
    }
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

  Future<Map<String, dynamic>> health() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/health',
        options: Options(headers: _buildHeaders()),
      );
      return response.data ?? {};
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
        if (cookies != null && cookies.isNotEmpty)
          'X-YouTube-Cookies': base64Encode(utf8.encode(cookies)),
      });

      try {
        final response = await _dio.get<Map<String, dynamic>>(
          '/api/streams',
          queryParameters: {'url': url},
          options: Options(headers: headers),
        );
        final data = response.data ?? {};

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
        throw _handleDioError(e);
      }
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
        if (cookies != null && cookies.isNotEmpty)
          'X-YouTube-Cookies': base64Encode(utf8.encode(cookies)),
      });

      try {
        final response = await _dio.get<Map<String, dynamic>>(
          '/api/playlist',
          queryParameters: {
            'url': url,
            if (pageToken != null) 'pageToken': pageToken.toString(),
            // ignore: use_null_aware_elements — key is non-null; if-guard is correct here
            if (pageSize != null) 'pageSize': pageSize,
          },
          options: Options(headers: headers),
        );
        return response.data ?? {};
      } catch (e) {
        throw _handleDioError(e);
      }
    });
  }

  Future<List<Map<String, dynamic>>> search(String q) async {
    return _rateLimiter.call('search', () async {
      try {
        final response = await _dio.get<Map<String, dynamic>>(
          '/api/search',
          queryParameters: {'q': q},
          options: Options(headers: _buildHeaders()),
        );
        final data = response.data ?? {};
        final results = data['results'] as List?;
        if (results == null) return [];
        return results.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } catch (e) {
        throw _handleDioError(e);
      }
    });
  }

  BackendException _handleDioError(Object error) {
    if (error is BackendException) return error;

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
          backendMsg ?? 'Video is geo-restricted and not available from this server.',
        );
      } else if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.connectionError ||
          (statusCode != null && statusCode >= 500)) {
        return BackendNetworkException(
          backendMsg ??
              error.message ??
              'Cannot reach download backend. Check your connection.',
        );
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
      final retryAfter = 60 - now.difference(_endpoints[key]!.first).inSeconds;
      throw BackendRateLimitException(
        retryAfterSeconds: retryAfter,
        message: 'Rate limit exceeded for endpoint: $endpoint',
      );
    }

    _endpoints[key]!.add(now);
    return await request();
  }
}
