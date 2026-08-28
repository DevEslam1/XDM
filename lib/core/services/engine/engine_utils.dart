import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/ssrf_guard.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/retry_interceptor.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;

/// Utility classes and functions for the Download Engine.
/// Task 1.2: Decoupled utilities.

class TimestampedEntry<V> {
  TimestampedEntry(this.value, [DateTime? time])
      : lastAccessed = time ?? DateTime.now();
  final V value;
  DateTime lastAccessed;
}

class TimestampedLruMap<K, V> {
  TimestampedLruMap({this.maxCapacity = 50});
  final int maxCapacity;
  final LinkedHashMap<K, TimestampedEntry<V>> _map = LinkedHashMap();

  int get length => _map.length;
  bool get isEmpty => _map.isEmpty;
  bool get isNotEmpty => _map.isNotEmpty;

  void clear() => _map.clear();

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

  DateTime? getLastAccessed(K key) => _map[key]?.lastAccessed;

  void removeStale(Duration threshold) {
    final now = DateTime.now();
    _map.removeWhere(
        (key, entry) => now.difference(entry.lastAccessed) > threshold);
  }

  List<K> get keys => _map.keys.toList();
}

Dio buildTransferDio({
  String? url,
  String? customUserAgent,
  String? referer,
  String? cookies,
  String? oauthToken,
  Dio? pooled,
  String? authUsername,
  String? authPassword,
  Map<String, String>? customHeaders,
  bool httpsOnly = false,
  String? proxyType,
  String? proxyHost,
  int? proxyPort,
  String? proxyUsername,
  String? proxyPassword,
}) {
  final client = pooled ?? Dio();
  if (pooled == null) {
    client.interceptors.add(ProfessionalRetryInterceptor(client));
    client.options.connectTimeout = const Duration(seconds: 30);
    client.options.sendTimeout = const Duration(seconds: 60);
    client.options.receiveTimeout = const Duration(seconds: 60);
    // M-1: SSRF + cleartext guard. Validate the initial request URL and every
    // redirect hop dart:io auto-followed, so a link that redirects to
    // 169.254.169.254 / 127.0.0.1 (or an integer-encoded form) is refused on
    // the download path. Added only on freshly-built (non-pooled) clients so
    // the interceptor isn't stacked twice.
    client.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        try {
          // Initial (and non-redirect) requests allow LAN/loopback/private
          // targets so users can download from their own NAS/router/localhost,
          // while metadata/link-local/0.0.0.0/multicast stay blocked.
          SsrfGuard.validate(options.uri,
              httpsOnly: httpsOnly, allowPrivate: true);
        } on SsrfBlockedException catch (e) {
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            error: e,
            message: e.message,
          ));
          return;
        }
        handler.next(options);
      },
      onResponse: (response, handler) {
        // Only redirect hops need the strict re-check. A no-redirect response
        // was already validated on the initial request (allowPrivate:true for a
        // user-typed URL). When the server issued a 3xx, re-validate every hop
        // and the final URI STRICTLY (allowPrivate:false) so a remote host
        // cannot pivot the download into the user's private network.
        if (response.redirects.isNotEmpty) {
          try {
            for (final r in response.redirects) {
              SsrfGuard.validate(r.location,
                  httpsOnly: httpsOnly, allowPrivate: false);
            }
            SsrfGuard.validate(response.realUri,
                httpsOnly: httpsOnly, allowPrivate: false);
          } on SsrfBlockedException catch (e) {
            handler.reject(DioException(
              requestOptions: response.requestOptions,
              type: DioExceptionType.badResponse,
              error: e,
              message: e.message,
            ));
            return;
          }
        }
        handler.next(response);
      },
    ));
  }

  final uri = url != null ? Uri.tryParse(url) : null;
  final host = uri?.host.toLowerCase() ?? '';
  final isYoutubeUrl = host.contains('youtube.com') ||
      host == 'youtu.be' ||
      host.endsWith('.googlevideo.com');

  if (isYoutubeUrl) {
    client.options.headers['Origin'] = 'https://www.youtube.com';
    client.options.headers['User-Agent'] =
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';
  } else if (customUserAgent != null && customUserAgent.isNotEmpty) {
    client.options.headers['User-Agent'] = customUserAgent;
  }

  if (referer != null && referer.isNotEmpty) {
    client.options.headers['Referer'] = referer;
  }
  if (cookies != null && cookies.isNotEmpty) {
    client.options.headers['Cookie'] = cookies;
  }
  if (oauthToken != null && oauthToken.isNotEmpty) {
    client.options.headers['Authorization'] = 'Bearer $oauthToken';
  } else if (authUsername != null && authUsername.isNotEmpty) {
    // Explicit per-download HTTP Basic credentials (Plan 06 6.2).
    final basic =
        base64Encode(utf8.encode('$authUsername:${authPassword ?? ''}'));
    client.options.headers['Authorization'] = 'Basic $basic';
  } else if (url != null) {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.userInfo.isNotEmpty) {
      final base64Auth =
          base64Encode(utf8.encode(Uri.decodeComponent(uri.userInfo)));
      client.options.headers['Authorization'] = 'Basic $base64Auth';
    }
  }

  // Apply user-supplied custom headers LAST so they win over any header
  // derived above (including a user-provided Authorization override).
  if (customHeaders != null) {
    customHeaders.forEach((k, v) {
      if (k.trim().isNotEmpty) client.options.headers[k] = v;
    });
  }

  final useHttpProxy = proxyType == 'http' &&
      proxyHost != null &&
      proxyHost.isNotEmpty &&
      (proxyPort ?? 0) > 0;

  if (client.httpClientAdapter is IOHttpClientAdapter) {
    final adapter = client.httpClientAdapter as IOHttpClientAdapter;
    // FIX-A: validateCertificate conflicts with a custom createHttpClient
    // (the adapter's default client creation consults it and can short-circuit
    // the debug bypass). Null it out so only badCertificateCallback governs.
    adapter.validateCertificate = null;
    adapter.createHttpClient = () {
      final httpClient = HttpClient();
      httpClient.badCertificateCallback = DebugCertOverride.getCallback(url);
      if (useHttpProxy) {
        // dart:io HttpClient supports HTTP CONNECT proxies only; SOCKS5 is
        // handled natively by libtorrent, never here.
        httpClient.findProxy = (_) => 'PROXY $proxyHost:$proxyPort';
        if (proxyUsername != null && proxyUsername.isNotEmpty) {
          httpClient.addProxyCredentials(
            proxyHost,
            proxyPort!,
            '',
            HttpClientBasicCredentials(proxyUsername, proxyPassword ?? ''),
          );
        }
      }
      return httpClient;
    };
  }

  return client;
}

class DebugCertOverride {
  static const bool allowDebugCert =
      bool.fromEnvironment('ALLOW_DEBUG_CERT', defaultValue: false);

  /// Debug-only SSL/TLS bypass.
  /// Strictly disabled in release mode (kReleaseMode) to guarantee TLS security.
  static BadCertificateCallback? getCallback(String? url,
      {bool? allowDebugCertOverride}) {
    // FIX-4.4: Hard guard for release mode as first line to guarantee TLS security
    if (kReleaseMode) return null;
    final enabled = allowDebugCertOverride ?? allowDebugCert;
    bool isDebug = false;
    assert(() {
      isDebug = true;
      return true;
    }());
    if (!isDebug && !enabled) return null;
    return (X509Certificate cert, String host, int port) => true;
  }
}

String? firstNonEmpty(String? a, String? b) {
  if (a != null && a.trim().isNotEmpty) return a;
  if (b != null && b.trim().isNotEmpty) return b;
  return null;
}

Future<int> actualDownloadedBytes(String tempFilePath,
    {int threadCount = 1, StateStoreInstance? stateStore}) async {
  final file = File(tempFilePath);
  if (!await file.exists()) return 0;
  final fileLen = await file.length();
  final state = stateStore != null
      ? await stateStore.load(tempFilePath)
      : await StateStore.load(tempFilePath);
  if (state != null) {
    final stateBytes = state.downloadedBytes;
    if (state.totalSize > 0) {
      return math.min<int>(stateBytes, fileLen).clamp(0, state.totalSize);
    }
    return math.min<int>(stateBytes, fileLen);
  }
  // When state file is missing, multi-threaded downloads use preallocation
  // so file length does not reflect downloaded bytes. Return 0 instead.
  if (threadCount > 1) {
    return 0;
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
    } catch (e, st) {
      LoggingService.logger('EngineUtils').warning('Operation failed', e, st);
    }
  }
  return false;
}

/// M-3: decides whether a single-stream download whose total size was never
/// known (no usable Content-Length) can be trusted as *complete* once its
/// response stream ends normally.
///
/// dart:io raises on a truncated Content-Length- or chunked-delimited body, so
/// a clean loop exit is only reached when the framing itself signalled the end:
/// - `Transfer-Encoding: chunked` — the terminating zero-length chunk arrived
///   (dart:io would have thrown otherwise);
/// - a close-delimited body (`Connection: close`, or a `Content-Length` we can
///   see) — the graceful socket close *is* the completion signal.
///
/// A keep-alive response carrying neither a length nor chunked framing has no
/// way to delimit its body, so a stream that simply stops may have been
/// truncated by an early socket close. Sealing those bytes as a finished file
/// is the M-3 bug; we reject them here so the transfer resumes/fails instead.
/// A zero-byte result is never a real file, regardless of framing.
bool unknownLengthEofIsTrustworthy(Headers headers, int bytesReceived) {
  if (bytesReceived <= 0) return false;
  final transferEncoding =
      headers.value('transfer-encoding')?.toLowerCase() ?? '';
  if (transferEncoding.contains('chunked')) return true;
  if (headers.value(Headers.contentLengthHeader) != null) return true;
  final connection = headers.value('connection')?.toLowerCase() ?? '';
  if (connection.contains('close')) return true;
  return false;
}
