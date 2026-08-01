import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

class ConnectionManager {
  static Dio createDownloadDio({
    int connectTimeoutMs = 15000,
    int receiveTimeoutMs = 60000,
    int maxConnectionsPerHost = 32,
    bool preferHttp3 = true,
  }) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: Duration(milliseconds: connectTimeoutMs),
        receiveTimeout: Duration(milliseconds: receiveTimeoutMs),
        followRedirects: true,
        maxRedirects: 10,
      ),
    );

    (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final client = HttpClient();
      client.maxConnectionsPerHost = maxConnectionsPerHost;
      client.connectionTimeout = Duration(milliseconds: connectTimeoutMs);
      client.idleTimeout = const Duration(seconds: 30);
      return client;
    };

    return dio;
  }

  /// Detects HTTP/3 (QUIC) support via the `Alt-Svc` response header.
  static Future<bool> detectHttp3(String url) async {
    try {
      final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 5)));
      final response = await dio.head(url);
      final altSvc = response.headers.value('alt-svc');
      return altSvc?.toLowerCase().contains('h3') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// No-op pre-warming.
  static Future<void> prewarm(String url) async {}

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
      rawSocket = null; // SecureSocket now owns rawSocket.
      final proto = secureSocket.selectedProtocol;
      await secureSocket.close();
      secureSocket = null;
      return proto == 'h2';
    } catch (_) {
      return false;
    } finally {
      secureSocket?.destroy();
      rawSocket?.destroy();
    }
  }
}
