import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../utils/url_utils.dart';

class SingleInstanceService {
  static final SingleInstanceService _instance =
      SingleInstanceService._internal();
  factory SingleInstanceService() => _instance;
  SingleInstanceService._internal();

  static const int _port = 37128;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _serverSubscription;
  void Function(String url)? _onUrlListener;
  String? _initialUrl;
  String? _securityToken;

  String? get initialUrl => _initialUrl;

  static File get _tokenFile {
    Directory targetDir = Directory.systemTemp;
    if (Platform.isLinux || Platform.isMacOS) {
      final userHome =
          Platform.environment['HOME'] ?? Directory.systemTemp.path;
      final configDir = Directory('$userHome/.config/xdm');
      if (!configDir.existsSync()) {
        try {
          configDir.createSync(recursive: true);
          Process.runSync('chmod', ['700', configDir.path]);
        } catch (e) {
          debugPrint(
            '[SingleInstanceService] Warning: Failed to create user config dir with 0700 perms: $e',
          );
        }
      }
      if (configDir.existsSync()) {
        targetDir = configDir;
      } else {
        debugPrint(
          '[SingleInstanceService] WARNING: Could not use ~/.config/xdm; '
          'falling back to system temp (${Directory.systemTemp.path}). '
          'Token may be readable by other users on this system.',
        );
      }
    } else if (Platform.isWindows) {
      // On Windows, use APPDATA which is restricted to the current user by default ACLs
      final appData =
          Platform.environment['APPDATA'] ??
          Platform.environment['LOCALAPPDATA'];
      if (appData != null && appData.isNotEmpty) {
        final configDir = Directory('$appData\\xdm');
        if (!configDir.existsSync()) {
          try {
            configDir.createSync(recursive: true);
          } catch (e) {
            debugPrint(
              '[SingleInstanceService] Warning: Failed to create user AppData dir: $e',
            );
          }
        }
        if (configDir.existsSync()) {
          targetDir = configDir;
        }
      }
    }
    return File('${targetDir.path}/xdm_instance_$_port.token');
  }

  String _generateSecurityToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  Future<bool> initialize(List<String> args) async {
    final candidateUrl = extractLaunchUrl(args);

    if (kIsWeb ||
        (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS)) {
      _initialUrl = candidateUrl;
      return true;
    }

    _securityToken = _generateSecurityToken();

    try {
      await _startServer(candidateUrl);
      return true;
    } on SocketException {
      // Bind failed — either another instance is running, or the previous instance crashed.
      final bool forwardedSuccessfully = await _tryForwardUrl(candidateUrl);

      if (forwardedSuccessfully) {
        // Primary instance is alive and received the URL. This instance should exit.
        return false;
      }

      // If forwarding failed, the existing instance is dead. Clean up stale token and retry.
      debugPrint(
        '[SingleInstanceService] Primary instance unresponsive. Cleaning up stale token.',
      );
      try {
        await _tokenFile.delete();
      } catch (_) {}

      try {
        await _startServer(candidateUrl);
        return true;
      } catch (e) {
        debugPrint('SingleInstanceService retry bind failed: $e');
        return false;
      }
    } catch (e) {
      debugPrint('SingleInstanceService init error: $e');
      _initialUrl = candidateUrl;
      return true;
    }
  }

  Future<void> _startServer(String? candidateUrl) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
    _initialUrl = candidateUrl;

    final tokenF = _tokenFile;
    if (!Platform.isWindows) {
      final tempTokenF = File('${tokenF.path}.tmp');
      try {
        await tempTokenF.writeAsString(_securityToken!);
        await Process.run('chmod', ['600', tempTokenF.path]);
        await tempTokenF.rename(tokenF.path);
      } catch (e) {
        debugPrint(
          '[SingleInstanceService] Warning: Atomic token write failed ($e); falling back to direct write.',
        );
        await tokenF.writeAsString(_securityToken!);
        try {
          await Process.run('chmod', ['600', tokenF.path]);
        } catch (_) {}
      }
    } else {
      // AppData directory is already restricted to the user by default ACLs on Windows
      await tokenF.writeAsString(_securityToken!);
    }

    _serverSubscription = _server?.listen((HttpRequest request) async {
      try {
        final tokenParam = request.uri.queryParameters['token'];
        if (tokenParam == null || tokenParam != _securityToken) {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }
        final urlParam = request.uri.queryParameters['url'];
        if (urlParam != null && urlParam.trim().isNotEmpty) {
          final decoded = Uri.decodeComponent(urlParam.trim());
          _onUrlListener?.call(decoded);
        }
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      } catch (e) {
        debugPrint('SingleInstanceServer request error: $e');
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {}
      }
    });
  }

  Future<bool> _tryForwardUrl(String? candidateUrl) async {
    if (candidateUrl == null || candidateUrl.isEmpty) return false;

    final client = HttpClient();
    client.connectionTimeout = const Duration(
      seconds: 3,
    ); // Short timeout for ping
    try {
      String? remoteToken;
      if (await _tokenFile.exists()) {
        remoteToken = (await _tokenFile.readAsString()).trim();
      }

      final queryParams = <String, String>{'url': candidateUrl};
      if (remoteToken != null && remoteToken.isNotEmpty) {
        queryParams['token'] = remoteToken;
      }
      final uri = Uri.http('127.0.0.1:$_port', '/', queryParams);
      final req = await client.getUrl(uri);
      await req.close();
      return true;
    } catch (e) {
      debugPrint('Failed to forward url to primary instance: $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  void setListener(void Function(String url) listener) {
    _onUrlListener = listener;
  }

  void clearListener() {
    _onUrlListener = null;
  }

  void dispose() {
    _serverSubscription?.cancel();
    _serverSubscription = null;
    _server?.close(force: true);
    _server = null;
    _onUrlListener = null;
    try {
      if (_tokenFile.existsSync()) _tokenFile.deleteSync();
    } catch (e) {
      debugPrint(
        '[SingleInstanceService] Failed to delete token file on dispose: $e',
      );
    }
  }

  static String? extractLaunchUrl(List<String> args) {
    if (args.isEmpty) return null;

    for (final arg in args) {
      final clean = arg.trim();
      if (clean.isEmpty || clean.startsWith('-')) continue;

      if (isMagnetUrl(clean) ||
          isTorrentFileUrl(clean) ||
          isHttpUrl(clean) ||
          clean.toLowerCase().endsWith('.torrent')) {
        return clean;
      }
    }
    return null;
  }
}
