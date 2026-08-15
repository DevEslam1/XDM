import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/protocol_cache.dart';

class ConnectionManager {
  ConnectionManager();
  static final Map<String, _HostProbe> _probes = {};
  static const Duration _cacheTtl = Duration(minutes: 10);
  static const Duration _probeTimeout = Duration(seconds: 4);
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
    } catch (_) {} // coverage:ignore-line
  }

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
      if (_probes.length > 500) {
        _probes
            .removeWhere((_, probe) => now.difference(probe.at) >= _cacheTtl);
        if (_probes.length > 500) {
          _probes.remove(_probes.keys.first);
        }
      }
      return result;
    } catch (e) {
      debugPrint('[ConnectionManager] detectHttp2 failed: $e');
      return false;
    }
  }

  static void invalidate(String host) {
    _probes.remove(host);
    ProtocolCache.invalidate(host);
  }
  static void clearCache() => _probes.clear();
  static Dio createDownloadDio() {
    final dio = Dio();
    dio.options.connectTimeout = const Duration(milliseconds: 15000);
    dio.options.receiveTimeout = const Duration(milliseconds: 60000);
    return dio;
  }

  static Dio createProtocolDio(ProtocolSupport protocol) {
    final dio = createDownloadDio();
    switch (protocol) {
      case ProtocolSupport.http3:
        dio.options.connectTimeout = const Duration(milliseconds: 10000);
        dio.options.receiveTimeout = const Duration(milliseconds: 45000);
        break;
      case ProtocolSupport.http2:
        dio.options.connectTimeout = const Duration(milliseconds: 12000);
        dio.options.receiveTimeout = const Duration(milliseconds: 60000);
        break;
      case ProtocolSupport.http11:
        break;
    }
    return dio;
  }

  static bool isGoawayOrReset(dynamic error) {
    if (error is DioException) {
      final msg = error.message?.toLowerCase() ?? '';
      return msg.contains('goaway') || msg.contains('reset');
    }
    return false;
  }

  static Future<ProtocolSupport> detectBestProtocol(String url) async {
    final cached = ProtocolCache.get(url);
    if (cached != null) return cached;
    final isH2 = await detectHttp2(url);
    if (isH2) {
      await ProtocolCache.record(url, ProtocolSupport.http2);
      return ProtocolSupport.http2;
    }
    await ProtocolCache.record(url, ProtocolSupport.http11);
    return ProtocolSupport.http11;
  }
}

class _HostProbe {
  const _HostProbe({required this.isHttp2, required this.at});
  final bool isHttp2;
  final DateTime at;
}
