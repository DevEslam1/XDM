import 'dart:io';

import 'package:flutter/foundation.dart';

/// Connection intelligence: TLS prewarm and ALPN-based HTTP/2 detection,
/// cached per host. Never throws — probes degrade to "assume HTTP/1.1".
import 'package:dio/dio.dart';
import 'package:dmx/core/services/protocol_cache.dart';

/// Connection intelligence: TLS prewarm and ALPN-based HTTP/2 detection,
/// cached per host. Never throws — probes degrade to "assume HTTP/1.1".
class ConnectionManager {
  ConnectionManager();

  static final Map<String, _HostProbe> _probes = {};
  static const Duration _cacheTtl = Duration(minutes: 10);
  static const Duration _probeTimeout = Duration(seconds: 4);

  /// Warms a TCP+TLS connection so the first Range request skips the
  /// handshake. Fire-and-forget; failures are ignored.
  static Future<void> prewarm(String url) async {
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != 'https') return;
      final socket = await SecureSocket.connect(
        uri.host,
        uri.hasPort ? uri.port : 443,
        timeout: _probeTimeout,
        supportedProtocols: const ['h2', 'http/1.1'],
      );
      await socket.close();
    } catch (_) {}
  }

  /// True when the host negotiates `h2` via ALPN. Cached for [_cacheTtl].
  static Future<bool> detectHttp2(String url) async {
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != 'https') return false;
      final host = uri.host;
      final cached = _probes[host];
      final now = DateTime.now();
      if (cached != null && now.difference(cached.at) < _cacheTtl) {
        return cached.isHttp2;
      }
      var result = false;
      try {
        final socket = await SecureSocket.connect(
          host,
          uri.hasPort ? uri.port : 443,
          timeout: _probeTimeout,
          supportedProtocols: const ['h2', 'http/1.1'],
        );
        result = socket.selectedProtocol == 'h2';
        await socket.close();
      } catch (_) {
        result = false;
      }
      _probes[host] = _HostProbe(isHttp2: result, at: now);
      return result;
    } catch (e) {
      debugPrint('[ConnectionManager] detectHttp2 failed: $e');
      return false;
    }
  }

  static void invalidate(String host) => _probes.remove(host);
  static void clearCache() => _probes.clear();

  static Dio createDownloadDio() {
    final dio = Dio();
    dio.options.connectTimeout = const Duration(milliseconds: 15000);
    dio.options.receiveTimeout = const Duration(milliseconds: 60000);
    return dio;
  }

  static Dio createProtocolDio(dynamic protocol) {
    return createDownloadDio();
  }

  static bool isGoawayOrReset(dynamic error) {
    if (error is DioException) {
      final msg = error.message?.toLowerCase() ?? '';
      return msg.contains('goaway') || msg.contains('reset');
    }
    return false;
  }

  static Future<ProtocolSupport> detectBestProtocol(String url) async {
    final isH2 = await detectHttp2(url);
    if (isH2) return ProtocolSupport.http2;
    return ProtocolSupport.http11;
  }
}

class _HostProbe {
  const _HostProbe({required this.isHttp2, required this.at});
  final bool isHttp2;
  final DateTime at;
}
