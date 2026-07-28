import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:logging/logging.dart';

class ConnectionManager {
  static final _log = Logger('ConnectionManager');

  static Dio createDownloadDio({
    int connectTimeoutMs = 15000,
    int receiveTimeoutMs = 60000,
    int maxConnectionsPerHost = 6,
  }) {
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(milliseconds: connectTimeoutMs),
      receiveTimeout: Duration(milliseconds: receiveTimeoutMs),
      followRedirects: true,
      maxRedirects: 10,
    ));

    (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final client = HttpClient();
      client.maxConnectionsPerHost = maxConnectionsPerHost;
      client.connectionTimeout = Duration(milliseconds: connectTimeoutMs);
      client.idleTimeout = const Duration(seconds: 30);
      return client;
    };

    return dio;
  }

  static Future<void> prewarm(String url) async {
    try {
      final uri = Uri.parse(url);
      final port = uri.hasPort
          ? uri.port
          : (uri.scheme == 'https' ? 443 : 80);

      final sw = Stopwatch()..start();
      final socket = await Socket.connect(
        uri.host,
        port,
        timeout: const Duration(seconds: 5),
      );

      if (uri.scheme == 'https') {
        final secure = await SecureSocket.secure(socket, host: uri.host);
        secure.write('HEAD ${uri.path.isEmpty ? '/' : uri.path} HTTP/1.1\r\n'
            'Host: ${uri.host}\r\n'
            'Connection: keep-alive\r\n\r\n');
        await secure.flush();
        await secure.first.timeout(
          const Duration(seconds: 3),
          onTimeout: () => Uint8List(0),
        );
        await secure.close();
      } else {
        socket.write('HEAD ${uri.path.isEmpty ? '/' : uri.path} HTTP/1.1\r\n'
            'Host: ${uri.host}\r\n'
            'Connection: keep-alive\r\n\r\n');
        await socket.flush();
        await socket.first.timeout(
          const Duration(seconds: 3),
          onTimeout: () => Uint8List(0),
        );
        await socket.close();
      }

      sw.stop();
      _log.fine('Pre-warmed ${uri.host}:$port in ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      _log.fine('Pre-warm failed (non-fatal) for $url: $e');
    }
  }

  static Future<bool> detectHttp2(String url) async {
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != 'https') return false;
      final port = uri.hasPort ? uri.port : 443;
      final socket = await Socket.connect(
        uri.host, port,
        timeout: const Duration(seconds: 5),
      );
      final secure = await SecureSocket.secure(socket, host: uri.host);
      final proto = secure.selectedProtocol;
      await secure.close();
      return proto == 'h2';
    } catch (_) {
      return false;
    }
  }
}