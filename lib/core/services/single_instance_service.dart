import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'logging_service.dart';
import '../utils/url_utils.dart';

class SingleInstanceService {
  static final SingleInstanceService _instance =
      SingleInstanceService._internal();
  factory SingleInstanceService() => _instance;
  SingleInstanceService._internal();

  static final _log = LoggingService.logger('SingleInstanceService');

  static const int _port = 37128;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _serverSubscription;
  void Function(String url)? _onUrlListener;
  String? _initialUrl;
  String? _securityToken;

  String? get initialUrl => _initialUrl;

  /// Returns the secure token file location.
  ///
  /// On Linux/macOS: `~/.config/xdm/xdm_instance_<port>.token` with dir 0700.
  /// On Windows: `%APPDATA%/xdm/xdm_instance_<port>.token` (user-ACL protected).
  ///
  /// NEVER falls back to world-readable system temp ([Directory.systemTemp]).
  /// If the secure directory cannot be created, single-instance forwarding is
  /// safely disabled (the caller handles this by failing closed).
  static File get _tokenFile {
    if (Platform.isLinux || Platform.isMacOS) {
      final userHome = Platform.environment['HOME'];
      if (userHome != null && userHome.isNotEmpty) {
        final configDir = Directory('$userHome/.config/xdm');
        try {
          if (!configDir.existsSync()) {
            configDir.createSync(recursive: true);
          }
          // Set 0700 on Unix — best-effort; if chmod is unavailable, the
          // umask should have created it with safe defaults on most systems.
          try {
            Process.runSync('chmod', ['700', configDir.path]);
          } catch (_) {}
          if (configDir.existsSync()) {
            final tokenFile = File('${configDir.path}/xdm_instance_$_port.token');
            return tokenFile;
          }
        } catch (e) {
          _log.severe('Failed to create secure config dir $userHome/.config/xdm', e);
          // Fail closed — do NOT fall back to temp.
          // Return a file in a non-existent path; _startServer will throw,
          // and the caller will disable single-instance forwarding safely.
        }
      }
      // Fail closed if HOME is unset or directory creation failed.
      return File('/nonexistent/xdm_instance_$_port.token');
    } else if (Platform.isWindows) {
      final appData =
          Platform.environment['APPDATA'] ??
          Platform.environment['LOCALAPPDATA'];
      if (appData != null && appData.isNotEmpty) {
        final configDir = Directory('$appData\\xdm');
        try {
          if (!configDir.existsSync()) {
            configDir.createSync(recursive: true);
          }
          if (configDir.existsSync()) {
            return File('${configDir.path}\\xdm_instance_$_port.token');
          }
        } catch (e) {
          _log.severe('Failed to create AppData config dir', e);
        }
      }
      // Fail closed on Windows too.
      return File('C:\\nonexistent\\xdm_instance_$_port.token');
    }
    // Web or unknown platform — no-op
    return File('/nonexistent/xdm_instance_$_port.token');
  }

  /// Timing-safe string comparison to prevent timing side-channel attacks.
  static bool _timingSafeEqual(String a, String b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
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

      _log.warning('Primary instance unresponsive. Checking token file age.');
      try {
        if (await _tokenFile.exists()) {
          final stat = await _tokenFile.stat();
          if (DateTime.now().difference(stat.modified) > const Duration(seconds: 10)) {
            await _tokenFile.delete();
          }
        }
      } catch (_) {}

      try {
        await _startServer(candidateUrl);
        return true;
      } catch (e) {
        _log.warning('Retry bind failed', e);
        return false;
      }
    } catch (e) {
      _log.warning('Init error', e);
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
        _log.warning('Atomic token write failed, falling back to direct write', e);
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
        if (tokenParam == null ||
            !_timingSafeEqual(tokenParam, _securityToken!)) {
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
        _log.warning('Server request error', e);
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
      final response = await req.close();
      return response.statusCode == HttpStatus.ok;
    } catch (e) {
      _log.warning('Failed to forward URL to primary instance', e);
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
      _log.warning('Failed to delete token file on dispose', e);
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
