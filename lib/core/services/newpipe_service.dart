import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Error categories surfaced by the local NewPipeExtractor bridge.
enum NewPipeErrorKind {
  ageRestricted,
  geoRestricted,
  signInRequired,
  noStreams,
  extractionFailed,
}

/// Thrown when native extraction fails. [userMessage] is already a friendly,
/// user-facing sentence that mirrors the old backend error prose so the UI and
/// download engine keep reacting the same way.
class NewPipeExtractionException implements Exception {
  final NewPipeErrorKind kind;
  final String message;
  final String? details;

  const NewPipeExtractionException(
    this.kind,
    this.message, {
    this.details,
  });

  String get userMessage {
    switch (kind) {
      case NewPipeErrorKind.signInRequired:
        return 'YouTube requires sign-in or bot verification. Please sign in '
            'to YouTube via the browser and try again.';
      case NewPipeErrorKind.ageRestricted:
        return 'This video is age-restricted.';
      case NewPipeErrorKind.geoRestricted:
        return 'This video is not available in your region.';
      case NewPipeErrorKind.noStreams:
        return 'No downloadable streams found.';
      case NewPipeErrorKind.extractionFailed:
        return message.isNotEmpty ? message : 'Failed to extract media.';
    }
  }

  @override
  String toString() => 'NewPipeExtractionException(${kind.name}): $message';
}

final class _CacheEntry {
  final Map<String, dynamic> value;
  final DateTime expiresAt;

  _CacheEntry(this.value, this.expiresAt);
}

/// MethodChannel wrapper around the native NewPipeExtractor bridge
/// (`com.dmx.app/newpipe`).
///
/// Only available on Android — every other platform throws [UnsupportedError].
/// Results are cached in memory (LRU, keyed by video id) for [_cacheTtl] so
/// refresh flows (stream URL expiry) never re-parse the same video twice in a
/// short window.
class NewPipeService {
  NewPipeService._();

  static final NewPipeService instance = NewPipeService._();

  static const MethodChannel _channel = MethodChannel('com.dmx.app/newpipe');

  /// How long a resolved stream set stays in the cache (10 minutes).
  static const Duration _cacheTtl = Duration(minutes: 10);
  static const int _maxCacheEntries = 50;

  final LinkedHashMap<String, _CacheEntry> _cache = LinkedHashMap();

  /// True on Android, where the native extraction bridge is available.
  bool get isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android;
  }

  void _ensureSupported() {
    if (!isSupported) {
      throw UnsupportedError(
        'Local NewPipe extraction is only available on Android.',
      );
    }
  }

  // ──────────────────────────── Streaming ─────────────────────────────

  /// Extracts streams for [url]. Returns the same shape the old backend used
  /// (`url`/`title`/`thumbnailUrl`/`source` + a `streams` list), so every
  /// existing parser keeps working unchanged.
  Future<Map<String, dynamic>> getVideoStreams(
    String url, {
    String? cookies,
    String? poToken,
    bool useCache = true,
  }) async {
    _ensureSupported();
    final cacheKey = _cacheKeyFor(url);
    if (useCache && cacheKey != null) {
      final hit = _cache.remove(cacheKey);
      if (hit != null && hit.expiresAt.isAfter(DateTime.now())) {
        _cache[cacheKey] = hit;
        return hit.value;
      }
      if (hit != null) _cache.remove(cacheKey);
    }

    final map = await _invoke(
      'getStreams',
      {'url': url, if (cookies != null) 'cookies': cookies, if (poToken != null) 'poToken': poToken},
    );
    final result = Map<String, dynamic>.from(map);
    if (cacheKey != null) {
      _cache[cacheKey] = _CacheEntry(result, DateTime.now().add(_cacheTtl));
      _trimCache();
    }
    return result;
  }

  /// Re-extracts a video whose stream URL went stale during download.
  Future<Map<String, dynamic>> resolveExpired(
    String url, {
    String? cookies,
    String? poToken,
  }) async {
    _ensureSupported();
    final map = await _invoke(
      'resolveExpired',
      {'url': url, if (cookies != null) 'cookies': cookies, if (poToken != null) 'poToken': poToken},
    );
    final result = Map<String, dynamic>.from(map);
    final cacheKey = _cacheKeyFor(url);
    if (cacheKey != null) {
      _cache[cacheKey] = _CacheEntry(result, DateTime.now().add(_cacheTtl));
      _trimCache();
    }
    return result;
  }

  // ──────────────────────────── Playlists ─────────────────────────────

  Future<Map<String, dynamic>> getPlaylist(
    String url, {
    String? cookies,
    String? pageToken,
  }) async {
    _ensureSupported();
    final map = await _invoke(
      'getPlaylist',
      {
        'url': url,
        if (cookies != null) 'cookies': cookies,
        if (pageToken != null && pageToken.toString().isNotEmpty) 'pageToken': pageToken,
      },
    );
    return Map<String, dynamic>.from(map);
  }

  // ────────────────────────────── Search ─────────────────────────────

  Future<List<Map<String, dynamic>>> search(
    String query, {
    int serviceId = 0,
    String? cookies,
  }) async {
    _ensureSupported();
    final raw = await _invoke('search', {
      'query': query,
      'cookies': cookies,
      'serviceId': serviceId,
    });
    return (raw as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  // ───────────────────────────── Internals ───────────────────────────

  Future<dynamic> _invoke(String method, Map<String, dynamic> arguments) async {
    try {
      return await _channel.invokeMethod(method, arguments).timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException('Native extraction timed out.'),
          );
    } on PlatformException catch (e) {
      throw _mapError(e);
    }
  }

  NewPipeExtractionException _mapError(PlatformException e) {
    final code = e.code;
    final message = e.message ?? '';
    switch (code) {
      case 'age_restricted':
        return NewPipeExtractionException(
          NewPipeErrorKind.ageRestricted,
          message,
          details: e.details?.toString(),
        );
      case 'geo_restricted':
        return NewPipeExtractionException(
          NewPipeErrorKind.geoRestricted,
          message,
          details: e.details?.toString(),
        );
      case 'sign_in_required':
        return NewPipeExtractionException(
          NewPipeErrorKind.signInRequired,
          message,
          details: e.details?.toString(),
        );
      case 'no_streams':
        return NewPipeExtractionException(
          NewPipeErrorKind.noStreams,
          message,
          details: e.details?.toString(),
        );
      default:
        return NewPipeExtractionException(
          NewPipeErrorKind.extractionFailed,
          message.isNotEmpty ? message : 'Failed to extract media.',
          details: e.details?.toString(),
        );
    }
  }

  /// A stable cache key for a URL: the video id when sensible, otherwise the
  /// normalized URL itself.
  String? _cacheKeyFor(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  }

  void _trimCache() {
    while (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// Clears the in-memory stream cache. Mainly used by tests.
  void clearCache() {
    _cache.clear();
  }
}