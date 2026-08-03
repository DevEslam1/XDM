import 'dart:async';
import 'dart:io';
import 'package:logging/logging.dart';
import 'doh_resolver.dart';
import '../../features/settings/provider/settings_provider.dart';

/// A minimal local HTTP proxy that routes traffic through Dart's networking.
/// This ensures that the native WebView respects Dart-side DNS (DoH) and proxy settings.
class LocalProxyService {
  static final _log = Logger('LocalProxyService');
  LocalProxyService._();
  static final LocalProxyService instance = LocalProxyService._();

  HttpServer? _server;
  int? get port => _server?.port;

  Future<void> start() async {
    if (_server != null) return;

    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _log.info('[LocalProxy] Started on port ${_server!.port}');

      _server!.listen((HttpRequest request) async {
        if (request.method == 'CONNECT') {
          await _handleConnect(request);
        } else {
          await _handleRegular(request);
        }
      }, onError: (e) => _log.warning('[LocalProxy] Server error: $e'));
    } catch (e) {
      _log.severe('[LocalProxy] Failed to start: $e');
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleConnect(HttpRequest request) async {
    final hostPort = request.uri.path.split(':');
    final host = hostPort[0];
    final port = hostPort.length > 1 ? (int.tryParse(hostPort[1]) ?? 443) : 443;

    final settings = SettingsProvider.instance;
    String targetHost = host;

    // Explicitly resolve via DoH for Socket connections (HTTPS tunnels)
    if (settings.dnsEnabled) {
      final resolved =
          await DohResolver.instance.resolve(host, settings.dnsProvider);
      if (resolved != null) {
        targetHost = resolved;
      }
    }

    try {
      final targetSocket =
          await Socket.connect(targetHost, port, timeout: const Duration(seconds: 15));
      
      // Send 200 OK to the client
      request.response.statusCode = HttpStatus.ok;
      request.response.reasonPhrase = 'Connection Established';
      
      // Detach and bridge
      final clientSocket = await request.response.detachSocket(writeHeaders: false);
      _bridgeSockets(clientSocket, targetSocket);
    } catch (e) {
      _log.warning('[LocalProxy] CONNECT failure to $host:$port: $e');
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    }
  }

  Future<void> _handleRegular(HttpRequest request) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    
    try {
      final targetRequest = await client.openUrl(request.method, request.uri);
      
      // Copy headers
      request.headers.forEach((name, values) {
        if (name != 'host') {
          for (var value in values) {
            targetRequest.headers.add(name, value);
          }
        }
      });

      // Stream body
      await targetRequest.addStream(request);
      final targetResponse = await targetRequest.close();

      // Copy response
      request.response.statusCode = targetResponse.statusCode;
      targetResponse.headers.forEach((name, values) {
        for (var value in values) {
          request.response.headers.add(name, value);
        }
      });

      await request.response.addStream(targetResponse);
    } catch (e) {
      _log.warning('[LocalProxy] Regular request failure: ${request.uri}: $e');
      request.response.statusCode = HttpStatus.serviceUnavailable;
    } finally {
      await request.response.close();
      client.close();
    }
  }

  void _bridgeSockets(Socket s1, Socket s2) {
    s1.listen(
      s2.add,
      onError: (e) {
        _log.fine('[LocalProxy] Socket 1 error: $e');
        s1.destroy();
        s2.destroy();
      },
      onDone: () {
        s2.close();
      },
      cancelOnError: true,
    );
    s2.listen(
      s1.add,
      onError: (e) {
        _log.fine('[LocalProxy] Socket 2 error: $e');
        s1.destroy();
        s2.destroy();
      },
      onDone: () {
        s1.close();
      },
      cancelOnError: true,
    );
  }
}
