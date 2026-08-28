import 'dart:collection';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/protocol_cache.dart';
import 'package:flutter/foundation.dart';

import 'service_registry.dart';

class ConnectionManager implements DisposableService, MemoryPressureListener {
  ConnectionManager() {
    ServiceRegistry.register(this);
    ServiceRegistry.registerMemoryPressureListener(this);
  }

  static final ConnectionManager instance = ConnectionManager();

  final LinkedHashMap<String, _HostProbe> _probes =
      LinkedHashMap<String, _HostProbe>();
  static const Duration _cacheTtl = Duration(minutes: 10);
  static const Duration _probeTimeout = Duration(seconds: 4);
  static const int _maxProbesCap = 150;

  @visibleForTesting
  int get probesCountForTesting => _probes.length;

  @visibleForTesting
  void recordProbeForTesting(String host, bool isHttp2) =>
      _recordProbe(host, isHttp2);

  @override
  void onMemoryPressure() {
    clearCache();
  }

  @override
  Future<void> dispose() async {
    ServiceRegistry.unregister(this);
    ServiceRegistry.unregisterMemoryPressureListener(this);
    clearCache();
  }

  Future<void> prewarm(String url) async {
    SecureSocket? socket;
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != 'https') return;
      socket = await SecureSocket.connect(
        uri.host,
        uri.hasPort ? uri.port : 443,
        timeout: _probeTimeout,
        supportedProtocols: const ['h2', 'http/1.1'],
      );
      final isH2 = socket.selectedProtocol == 'h2';
      _recordProbe(uri.host, isH2);
    } catch (e, st) {
      LoggingService.logger('ConnectionManager')
          .warning('Operation failed', e, st);
    } finally {
      socket?.close();
    }
  }

  void _recordProbe(String host, bool isHttp2) {
    final now = DateTime.now();
    _probes[host] = _HostProbe(isHttp2: isHttp2, at: now);
    if (_probes.length > _maxProbesCap) {
      _probes.removeWhere((_, probe) => now.difference(probe.at) >= _cacheTtl);
      while (_probes.length > _maxProbesCap) {
        _probes.remove(_probes.keys.first);
      }
    }
  }

  Future<bool> detectHttp2(String url) async {
    final pCache = ProtocolCache.get(url);
    if (pCache != null) return pCache == ProtocolSupport.http2;
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != 'https') return false;
      final host = uri.host;
      final cached = _probes.remove(host);
      final now = DateTime.now();
      if (cached != null) {
        if (now.difference(cached.at) < _cacheTtl) {
          _probes[host] = cached;
          return cached.isHttp2;
        }
      }
      var result = false;
      SecureSocket? socket;
      try {
        socket = await SecureSocket.connect(
          host,
          uri.hasPort ? uri.port : 443,
          timeout: _probeTimeout,
          supportedProtocols: const ['h2', 'http/1.1'],
        );
        result = socket.selectedProtocol == 'h2';
      } catch (_) {
        result = false;
      } finally {
        socket?.close();
      }
      _recordProbe(host, result);
      return result;
    } catch (e) {
      debugPrint('[ConnectionManager] detectHttp2 failed: $e');
      return false;
    }
  }

  void invalidate(String host) {
    _probes.remove(host);
    ProtocolCache.invalidate(host);
  }

  void clearCache() => _probes.clear();

  Future<ProtocolSupport> detectBestProtocol(String url) async {
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
}

class _HostProbe {
  const _HostProbe({required this.isHttp2, required this.at});
  final bool isHttp2;
  final DateTime at;
}
