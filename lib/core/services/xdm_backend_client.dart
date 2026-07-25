import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/constants.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'xdm_backend_exceptions.dart';

// TODO: Add per-device anonymous JWTs issued by Firebase Auth if further backend auth hardening is needed.

class XdmBackendClient {
  static final XdmBackendClient _instance = XdmBackendClient._internal();
  factory XdmBackendClient() => _instance;

  static const String _apiKeyFallback = 'KxPgwFT0VvqoJUgVfcWuvE3-QSrc7qM-1YDS1dzNJv0';
  static String? _apiKey;

  late Dio _dio;
  final Map<String, _StreamsCacheEntry> _streamsCache = {};

  static final _settings = SettingsProvider();
  static final _secureStorage = const FlutterSecureStorage();
  static const _apiKeyStorageKey = 'xdm_backend_api_key';

  /// Reads the API key from secure storage, falling back to the compile-time constant.
  /// Call this once at app startup before using the client.
  static Future<void> loadApiKey() async {
    try {
      final stored = await _secureStorage.read(key: _apiKeyStorageKey);
      if (stored != null && stored.isNotEmpty) {
        _apiKey = stored;
        return;
      }
    } catch (e) {
      debugPrint('[XdmBackendClient] Failed to read API key from secure storage: $e');
    }
    _apiKey = _apiKeyFallback;
  }

  /// Persists a new API key to secure storage and refreshes the Dio client.
  /// Pass an empty string to reset to the built-in fallback key.
  static Future<void> setApiKey(String key) async {
    if (key.isEmpty) {
      await _secureStorage.delete(key: _apiKeyStorageKey);
      _apiKey = _apiKeyFallback;
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
    final key = _apiKey ?? _apiKeyFallback;
    _dio = Dio(
      BaseOptions(
        baseUrl: _settings.backendUrl.isNotEmpty ? _settings.backendUrl : kDefaultBackendBaseUrl,
        connectTimeout: const Duration(seconds: 15),
        // Backend extraction can take up to 45 s; give a comfortable margin.
        receiveTimeout: const Duration(seconds: 60),
        headers: {
          'Accept': 'application/json',
          'Authorization': 'Bearer $key',
        },
      ),
    );

    if (kDebugMode) {
      debugPrint('[XdmBackendClient] Configured with backend URL: ${_settings.backendUrl.isNotEmpty ? _settings.backendUrl : kDefaultBackendBaseUrl}');
    }
  }

  /// Manually updates the backend configuration and refreshes the Dio client
  Future<void> updateBackendConfig(String backendUrl) async {
    await _settings.setBackendUrl(backendUrl);
    _updateDioFromSettings();
  }

  /// Refreshes the backend configuration from SettingsProvider
  Future<void> refreshConfig() async {
    await _settings.load();
    _updateDioFromSettings();
  }

  /// Get the current backend URL for UI display
  static String get currentBackendUrl => _settings.backendUrl;

  Future<Map<String, dynamic>> health() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/health');
      return response.data ?? {};
    } catch (e) {
      throw _handleDioError(e);
    }
  }

  Map<String, String> _buildHeaders([Map<String, String>? extra]) {
    final key = _apiKey ?? _apiKeyFallback;
    return {
      'Accept': 'application/json',
      'Authorization': 'Bearer $key',
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
  }

  /// Fetches playlist metadata and video list for a YouTube playlist URL.
  ///
  /// [cookies] — forwarded as `X-YouTube-Cookies`.
  Future<Map<String, dynamic>> getPlaylist(
    String url, {
    String? cookies,
  }) async {
    final headers = _buildHeaders({
      if (cookies != null && cookies.isNotEmpty)
        'X-YouTube-Cookies': base64Encode(utf8.encode(cookies)),
    });

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/playlist',
        queryParameters: {'url': url},
        options: Options(headers: headers),
      );
      return response.data ?? {};
    } catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<List<Map<String, dynamic>>> search(String q) async {
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
