import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

class ConnectionManager {
  static Dio createDownloadDio({
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

    (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final client = HttpClient();
      client.maxConnectionsPerHost = maxConnectionsPerHost;
      client.connectionTimeout = Duration(milliseconds: connectTimeoutMs);
      client.idleTimeout = const Duration(seconds: 30);
      return client;
    };

    return dio;
  }

  /// No-op. Pre-warming opens a connection, reads the response, and closes it,
  /// but the subsequent download opens a brand-new connection anyway, doubling
  /// setup time for no measurable benefit. The retry interceptor already
  /// handles transient connection failures.
  static Future<void> prewarm(String url) async {
    // Intentionally empty — see doc comment above.
  }

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
