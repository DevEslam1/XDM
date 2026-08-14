import 'dart:collection';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dmx/core/services/retry_interceptor.dart';

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
    (client.httpClientAdapter as IOHttpClientAdapter).onHttpClientCreate = (client) {
      client.badCertificateCallback = (cert, host, port) => true;
      return client;
    };
  }

  return client;
}

String? firstNonEmpty(String? a, String? b) {
  if (a != null && a.trim().isNotEmpty) return a;
  if (b != null && b.trim().isNotEmpty) return b;
  return null;
}
