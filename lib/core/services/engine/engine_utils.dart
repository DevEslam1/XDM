import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dmx/core/services/retry_interceptor.dart';
import 'package:dmx/core/services/download_journal.dart';

/// Utility classes and functions for the Download Engine.
/// Task 1.2: Decoupled utilities.

class TimestampedEntry<V> {
  TimestampedEntry(this.value, [DateTime? time])
      : lastAccessed = time ?? DateTime.now();
  final V value;
  DateTime lastAccessed;
}

class TimestampedLruMap<K, V> {
  TimestampedLruMap({this.maxCapacity = 100});
  final int maxCapacity;
  final LinkedHashMap<K, TimestampedEntry<V>> _map = LinkedHashMap();

  int get length => _map.length;

  V? get(K key) {
    final entry = _map.remove(key);
    if (entry == null) return null;
    entry.lastAccessed = DateTime.now();
    _map[key] = entry;
    return entry.value;
  }

  void put(K key, V value) {
    _map.remove(key);
    if (_map.length >= maxCapacity) {
      _map.remove(_map.keys.first);
    }
    _map[key] = TimestampedEntry(value);
  }

  V? operator [](K key) => get(key);
  void operator []=(K key, V value) => put(key, value);

  bool containsKey(K key) => _map.containsKey(key);

  V? remove(K key) {
    final entry = _map.remove(key);
    return entry?.value;
  }

  void removeStale(Duration threshold) {
    final now = DateTime.now();
    _map.removeWhere((key, entry) => now.difference(entry.lastAccessed) > threshold);
  }

  List<K> get keys => _map.keys.toList();
}

Dio buildTransferDio({
  String? url,
  String? customUserAgent,
  String? referer,
  String? cookies,
  String? oauthToken,
}) {
  final client = Dio();
  client.interceptors.add(ProfessionalRetryInterceptor(client));
  client.options.connectTimeout = const Duration(seconds: 30);
  client.options.sendTimeout = const Duration(seconds: 60);
  client.options.receiveTimeout = const Duration(seconds: 60);
  
  final uri = url != null ? Uri.tryParse(url) : null;
  final host = uri?.host.toLowerCase() ?? '';
  final isYoutubeUrl = host.contains('youtube.com') || host == 'youtu.be' || host.endsWith('.googlevideo.com');

  if (isYoutubeUrl) {
    client.options.headers['Origin'] = 'https://www.youtube.com';
    client.options.headers['User-Agent'] = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';
  } else if (customUserAgent != null && customUserAgent.isNotEmpty) {
    client.options.headers['User-Agent'] = customUserAgent;
  }
  
  if (referer != null && referer.isNotEmpty) client.options.headers['Referer'] = referer;
  if (cookies != null && cookies.isNotEmpty) client.options.headers['Cookie'] = cookies;
  if (oauthToken != null && oauthToken.isNotEmpty) client.options.headers['Authorization'] = 'Bearer $oauthToken';

  if (client.httpClientAdapter is IOHttpClientAdapter) {
    (client.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final client = HttpClient();
      client.badCertificateCallback = DebugCertOverride.getCallback(url);
      return client;
    };
  }

  return client;
}

class DebugCertOverride {
  static BadCertificateCallback? getCallback(String? url) {
    if (kReleaseMode) return null;
    bool isDebug = false;
    assert(() {
      isDebug = true;
      return true;
    }());
    if (!isDebug) return null;

    return (X509Certificate cert, String host, int port) {
      final targetHost = Uri.tryParse(url ?? '')?.host.toLowerCase();
      if (targetHost != null && host.toLowerCase().endsWith(targetHost)) return true;
      return false;
    };
  }
}

String? firstNonEmpty(String? a, String? b) {
  if (a != null && a.trim().isNotEmpty) return a;
  if (b != null && b.trim().isNotEmpty) return b;
  return null;
}

Future<int> actualDownloadedBytes(String tempFilePath, {int threadCount = 1}) async {
  final file = File(tempFilePath);
  if (!await file.exists()) return 0;
  final fileLen = await file.length();
  final state = await StateStore.load(tempFilePath);
  if (state != null) {
    final stateBytes = state.downloadedBytes;
    if (state.totalSize > 0) {
      return math.min(stateBytes, fileLen).clamp(0, state.totalSize);
    }
    return math.min(stateBytes, fileLen);
  }
  return fileLen;
}

bool isLikelyHtmlResponse(Headers headers, {List<int>? firstChunk}) {
  final contentType = headers.value('content-type')?.toLowerCase() ?? '';
  if (contentType.contains('text/html') ||
      contentType.contains('application/xhtml')) {
    return true;
  }
  if (firstChunk != null && firstChunk.isNotEmpty) {
    try {
      final sample = String.fromCharCodes(firstChunk.take(512)).toLowerCase();
      if (sample.contains('<!doctype html') ||
          sample.contains('<html') ||
          sample.contains('<head') ||
          sample.contains('<body')) {
        return true;
      }
    } catch (_) {}
  }
  return false;
}
