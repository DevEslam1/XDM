import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../utils/constants.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'xdm_backend_exceptions.dart';

// TODO: Add per-device anonymous JWTs issued by Firebase Auth if further backend auth hardening is needed.

class XdmBackendClient {
  static final XdmBackendClient _instance = XdmBackendClient._internal();
  factory XdmBackendClient() => _instance;

  late final Dio _dio;
  final Map<String, _StreamsCacheEntry> _streamsCache = {};

  static final _settings = SettingsProvider();

  XdmBackendClient._internal() {
    _updateDioFromSettings();
  }

  /// Updates the backend configuration from SettingsProvider
  void _updateDioFromSettings() {
    _dio = Dio(
      BaseOptions(
        baseUrl: _settings.backendUrl.isNotEmpty ? _settings.backendUrl : kDefaultBackendBaseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: {
          'Accept': 'application/json',
        },
      ),
    );
    
    if (_settings.backendToken.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer ${_settings.backendToken}';
    }
    
    if (kDebugMode) {
      debugPrint('[XdmBackendClient] Configured with backend URL: ${_settings.backendUrl.isNotEmpty ? _settings.backendUrl : kDefaultBackendBaseUrl}');
    }
  }

  /// Manually updates the backend configuration and refreshes the Dio client
  Future<void> updateBackendConfig(String backendUrl, String backendToken) async {
    await _settings.setBackendUrl(backendUrl);
    await _settings.setBackendToken(backendToken);
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

  Future<Map<String, dynamic>> getStreams(
    String url, {
    String? oauthToken,
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

    final headers = {
      if (oauthToken != null && oauthToken.isNotEmpty)
        'X-YT-OAuth': 'Bearer $oauthToken',
      if (cookies != null && cookies.isNotEmpty)
        'X-YouTube-Cookies': cookies,
      if (cookies != null && cookies.isNotEmpty)
        'X-YT-Cookies': cookies,
    };

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
      if (e is DioException && e.response?.statusCode == 404) {
        try {
          final response = await _dio.post<Map<String, dynamic>>(
            '/extract',
            data: {'url': url},
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
        } catch (postErr) {
          throw _handleDioError(postErr);
        }
      }
      throw _handleDioError(e);
    }
  }

  Future<Map<String, dynamic>> getPlaylist(
    String url, {
    String? oauthToken,
    String? cookies,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/playlist',
        queryParameters: {'url': url},
        options: Options(
          headers: {
            if (oauthToken != null && oauthToken.isNotEmpty)
              'X-YT-OAuth': 'Bearer $oauthToken',
            if (cookies != null && cookies.isNotEmpty) 'X-YT-Cookies': cookies,
          },
        ),
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
        return BackendRateLimitException(retryAfterSeconds: retryAfter);
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
