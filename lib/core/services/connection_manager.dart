import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'protocol_cache.dart';
import 'protocol_fallback_memory.dart';
import 'package:logging/logging.dart';

class ConnectionManager {
  static Dio createDownloadDio({
    int connectTimeoutMs = 15000,
    int receiveTimeoutMs = 60000,
    int maxConnectionsPerHost = 32,
    bool preferHttp3 = true,
  }) {
    return createProtocolDio(
      preferHttp3 ? ProtocolSupport.http3 : ProtocolSupport.http2,
      connectTimeoutMs: connectTimeoutMs,
      receiveTimeoutMs: receiveTimeoutMs,
      maxConnectionsPerHost: maxConnectionsPerHost,
    );
  }

  static Dio createProtocolDio(
    ProtocolSupport support, {
    int connectTimeoutMs = 15000,
    int receiveTimeoutMs = 60000,
    int maxConnectionsPerHost = 32,
  }) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: Duration(milliseconds: connectTimeoutMs),
        receiveTimeout: Duration(milliseconds: receiveTimeoutMs),
        followRedirects: true,
        maxRedirects: 10,
      ),
    );

    final adapter = IOHttpClientAdapter();
    adapter.createHttpClient = () {
      final client = HttpClient();
      client.maxConnectionsPerHost =
          support == ProtocolSupport.http2 ? 1 : maxConnectionsPerHost;
      client.connectionTimeout = Duration(milliseconds: connectTimeoutMs);
      client.idleTimeout = const Duration(seconds: 30);
      return client;
    };
    dio.httpClientAdapter = adapter;

    return dio;
  }

  /// Detects the BEST protocol a host supports by inspecting Alt-Svc / ALPN.
  static Future<ProtocolSupport> detectBestProtocol(
    String url, {
    Dio? dio,
  }) async {
    final cached = ProtocolCache.get(url);
    if (cached != null) return cached;

    if (ProtocolFallbackMemory.recentlyFailed(url, ProtocolSupport.http3)) {
      return ProtocolSupport.http2;
    }

    final client = dio ??
        Dio(BaseOptions(
          receiveTimeout: const Duration(seconds: 5),
          connectTimeout: const Duration(seconds: 5),
        ));

    try {
      final resp = await client.head(
        url,
        options: Options(validateStatus: (_) => true),
      );
      final altSvc = resp.headers.value('alt-svc') ?? '';
      final isH2 = resp.headers.value('x-protocol') == 'h2' ||
          resp.headers.value('x-firefox-spdy') == 'h2' ||
          await detectHttp2(url);

      ProtocolSupport support;
      if (altSvc.toLowerCase().contains('h3')) {
        support = ProtocolSupport.http3;
      } else if (isH2) {
        support = ProtocolSupport.http2;
      } else {
        support = ProtocolSupport.http11;
      }

      await ProtocolCache.record(url, support);
      return support;
    } catch (e, st) {
      Logger('connection_manager')
          .warning('[connection_manager] operation failed', e, st);
      return ProtocolSupport.http11;
    }
  }

  /// Detects HTTP/3 (QUIC) support via the `Alt-Svc` response header.
  static Future<bool> detectHttp3(String url) async {
    final support = await detectBestProtocol(url);
    return support == ProtocolSupport.http3;
  }

  /// Helper to check if an error is a GOAWAY or Stream Reset error.
  static bool isGoawayOrReset(Object error) {
    if (error is DioException) {
      final msg = error.message?.toLowerCase() ?? '';
      return msg.contains('goaway') ||
          msg.contains('stream was reset') ||
          msg.contains('refused_stream');
    }
    return false;
  }

  /// Pre-warms QUIC / TLS connections for 0-RTT session resumption.
  static Future<void> prewarm(String url) async {
    final support = await detectBestProtocol(url);
    final dio = createProtocolDio(support);
    try {
      await dio.head(
        url,
        options: Options(
          receiveTimeout: const Duration(seconds: 3),
          validateStatus: (_) => true,
        ),
      );
    } catch (e, st) {
      Logger('connection_manager')
          .warning('[connection_manager] operation failed', e, st);
    } finally {
      dio.close();
    }
  }

  /// Detects HTTP/2 ALPN support via SecureSocket TLS handshake.
  static Future<bool> detectHttp2(String url) async {
    Socket? rawSocket;
    SecureSocket? secureSocket;
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != 'https') return false;
      final port = uri.hasPort ? uri.port : 443;
      rawSocket = await Socket.connect(
        uri.host,
        port,
        timeout: const Duration(seconds: 5),
      );
      secureSocket = await SecureSocket.secure(
        rawSocket,
        host: uri.host,
        onBadCertificate: (_) => true,
      );
      rawSocket = null;
      final proto = secureSocket.selectedProtocol;
      await secureSocket.close();
      secureSocket = null;
      return proto == 'h2';
    } catch (e, st) {
      Logger('connection_manager')
          .warning('[connection_manager] operation failed', e, st);
      return false;
    } finally {
      secureSocket?.destroy();
      rawSocket?.destroy();
    }
  }
}
