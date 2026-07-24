import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../utils/url_utils.dart';

class SingleInstanceService {
  static final SingleInstanceService _instance = SingleInstanceService._internal();
  factory SingleInstanceService() => _instance;
  SingleInstanceService._internal();

  static const int _port = 37128;
  HttpServer? _server;
  void Function(String url)? _onUrlListener;
  String? _initialUrl;

  String? get initialUrl => _initialUrl;

  /// Call this in `main(List<String> args)`.
  /// Returns `true` if this instance should continue running,
  /// or `false` if this was a secondary instance that forwarded its args and exited.
  Future<bool> initialize(List<String> args) async {
    final candidateUrl = extractLaunchUrl(args);

    if (kIsWeb || (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS)) {
      _initialUrl = candidateUrl;
      return true;
    }

    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
      _initialUrl = candidateUrl;

      _server?.listen((HttpRequest request) async {
        try {
          final urlParam = request.uri.queryParameters['url'];
          if (urlParam != null && urlParam.trim().isNotEmpty) {
            final decoded = Uri.decodeComponent(urlParam.trim());
            if (_onUrlListener != null) {
              _onUrlListener!(decoded);
            }
          }
        } catch (e) {
          debugPrint('SingleInstanceServer request error: $e');
        } finally {
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();
        }
      });

      return true;
    } on SocketException {
      // Server already running in primary instance! Forward candidateUrl if present.
      if (candidateUrl != null && candidateUrl.isNotEmpty) {
        try {
          final client = HttpClient();
          final uri = Uri.http('127.0.0.1:$_port', '/', {'url': candidateUrl});
          final req = await client.getUrl(uri);
          await req.close();
          client.close();
        } catch (e) {
          debugPrint('Failed to forward url to primary instance: $e');
        }
      }
      return false; // Exit secondary instance
    } catch (e) {
      debugPrint('SingleInstanceService init error: $e');
      _initialUrl = candidateUrl;
      return true;
    }
  }

  void setListener(void Function(String url) listener) {
    _onUrlListener = listener;
  }

  void clearListener() {
    _onUrlListener = null;
  }

  void dispose() {
    _server?.close(force: true);
    _server = null;
    _onUrlListener = null;
  }

  static String? extractLaunchUrl(List<String> args) {
    if (args.isEmpty) return null;

    for (final arg in args) {
      final clean = arg.trim();
      if (clean.isEmpty || clean.startsWith('-')) continue;

      if (isMagnetUrl(clean) ||
          isTorrentFileUrl(clean) ||
          isHttpUrl(clean) ||
          clean.toLowerCase().endsWith('.torrent') ||
          File(clean).existsSync()) {
        return clean;
      }
    }
    return null;
  }
}
