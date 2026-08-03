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

  /// Pure token file path — NO side effects (FIX(25)). Directory creation and
  /// permissions are handled by [_ensureTokenDirectory].
  ///
  /// On Linux/macOS: `~/.config/xdm/xdm_instance_<port>.token` with dir 0700.
  /// On Windows: `%APPDATA%/xdm/xdm_instance_<port>.token` (user-ACL protected).
  ///
  /// NEVER falls back to world-readable system temp ([Directory.systemTemp]).
  static File get _tokenFile {
    if (Platform.isLinux || Platform.isMacOS) {
      final userHome = Platform.environment['HOME'];
      if (userHome != null && userHome.isNotEmpty) {
        return File('$userHome/.config/xdm/xdm_instance_$_port.token');
      }
      // Fail closed if HOME is unset.
      return File('/nonexistent/xdm_instance_$_port.token');
    } else if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ??
          Platform.environment['LOCALAPPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return File('$appData\\xdm\\xdm_instance_$_port.token');
      }
      // Fail closed on Windows too.
      return File('C:\\nonexistent\\xdm_instance_$_port.token');
    }
    // Web or unknown platform — no-op
    return File('/nonexistent/xdm_instance_$_port.token');
  }

  /// FIX(25): creates the secure token directory (and sets 0700 on Unix) as an
  /// explicit step, instead of doing I/O inside the `_tokenFile` getter.
  /// Best-effort: failures are logged; [dispose] and callers still guard
  /// against a missing file.
  Future<void> _ensureTokenDirectory() async {
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        final userHome = Platform.environment['HOME'];
        if (userHome == null || userHome.isEmpty) return;
        final configDir = Directory('$userHome/.config/xdm');
        if (!configDir.existsSync()) {
          configDir.createSync(recursive: true);
        }
        try {
          await Process.run('chmod', ['700', configDir.path]);
        } catch (e) {
          _log.info('[SingleInstanceService] chmod on token dir skipped: $e');
        }
      } else if (Platform.isWindows) {
        final appData = Platform.environment['APPDATA'] ??
            Platform.environment['LOCALAPPDATA'];
        if (appData == null || appData.isEmpty) return;
        final configDir = Directory('$appData\\xdm');
        if (!configDir.existsSync()) {
          configDir.createSync(recursive: true);
        }
      }
    } catch (e) {
      _log.severe('Failed to create secure token directory', e);
    }
  }

  /// Timing-safe string comparison to prevent timing side-channel attacks.
  /// Pads both inputs to [_maxTokenLength] so that length mismatches do not
  /// short-circuit and leak the token length.
  static const int _maxTokenLength = 256;

  static bool _timingSafeEqual(String a, String b) {
    if (a.length > _maxTokenLength || b.length > _maxTokenLength) return false;
    final paddedA = a.padRight(_maxTokenLength, '\x00');
    final paddedB = b.padRight(_maxTokenLength, '\x00');
    int result = 0;
    for (int i = 0; i < _maxTokenLength; i++) {
      result |= paddedA.codeUnitAt(i) ^ paddedB.codeUnitAt(i);
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

    // FIX(25): prepare the token directory up-front (getter is side-effect free).
    await _ensureTokenDirectory();

    // FIX(9/10): detect a live primary up-front using the token file (which
    // now records the actual bound port) + a TCP heartbeat. With port-0
    // binding we can no longer rely on a bind conflict to discover the
    // primary, so we probe before binding.
    final primaryInfo = await _readTokenFile();
    if (primaryInfo != null && await _isPrimaryAlive(primaryInfo.$2)) {
      // Primary is alive: forward the launch URL (if any), then this
      // secondary instance exits.
      if (candidateUrl != null && candidateUrl.isNotEmpty) {
        await _forwardTo(primaryInfo.$1, primaryInfo.$2, candidateUrl);
      }
      return false;
    }

    // No live primary — clean the stale token file, then become the primary.
    try {
      if (await _tokenFile.exists()) await _tokenFile.delete();
    } catch (e) {
      _log.info('[SingleInstanceService] deleting stale token file failed: $e');
    }

    try {
      await _startServer(candidateUrl);
      return true;
    } catch (e) {
      _log.warning('Init error', e);
      _initialUrl = candidateUrl;
      return true;
    }
  }

  Future<void> _startServer(String? candidateUrl) async {
    // FIX(9): bind to port 0 so the OS assigns an ephemeral, guaranteed-free
    // port. The fixed default port could be stolen by another process,
    // breaking the "single instance" guarantee. The actual bound port is
    // recorded in the token file so secondary instances can reach us.
    await _ensureTokenDirectory();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final actualPort = _server!.port;
    _initialUrl = candidateUrl;

    // Token file format: "<token>\n<port>". Port is on its own line so a
    // secondary instance can find us without assuming a fixed port.
    final tokenContents = '$_securityToken\n$actualPort';

    final tokenF = _tokenFile;
    if (!Platform.isWindows) {
      final tempTokenF = File('${tokenF.path}.tmp');
      try {
        await tempTokenF.writeAsString(tokenContents);
        await Process.run('chmod', ['600', tempTokenF.path]);
        await tempTokenF.rename(tokenF.path);
      } catch (e) {
        _log.warning(
          'Atomic token write failed, falling back to direct write',
          e,
        );
        await tokenF.writeAsString(tokenContents);
        try {
          await Process.run('chmod', ['600', tokenF.path]);
        } catch (e) {
          _log.info('[SingleInstanceService] chmod on token file skipped: $e');
        }
      }
    } else {
      // AppData directory is already restricted to the user by default ACLs on Windows
      await tokenF.writeAsString(tokenContents);
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
        } catch (e) {
          _log.info(
              '[SingleInstanceService] closing error response failed: $e');
        }
      }
    });
  }

  /// TCP heartbeat: does something accept connections on [port]?
  Future<bool> _isPrimaryAlive(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      );
      await socket.close();
      return true;
    } catch (e) {
      _log.info('[SingleInstanceService] primary heartbeat probe failed: $e');
      return false;
    }
  }

  /// Reads (token, port) from the token file. Handles both the current
  /// `"<token>\n<port>"` format and legacy single-line files (which default to
  /// the fixed [_port]).
  Future<(String, int)?> _readTokenFile() async {
    try {
      if (!await _tokenFile.exists()) return null;
      final contents = (await _tokenFile.readAsString()).trim();
      if (contents.isEmpty) return null;
      final lines = contents.split('\n');
      final token = lines.first.trim();
      if (token.isEmpty) return null;
      int port = _port;
      if (lines.length >= 2) {
        final parsed = int.tryParse(lines[1].trim());
        if (parsed != null && parsed > 0) port = parsed;
      }
      return (token, port);
    } catch (e) {
      _log.info(
        '[SingleInstanceService] reading token file failed, returning null: $e',
      );
      return null;
    }
  }

  /// Forwards [candidateUrl] to the primary instance on [port] using [token].
  Future<bool> _forwardTo(String token, int port, String candidateUrl) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);
    try {
      final queryParams = <String, String>{
        'url': candidateUrl,
        'token': token,
      };
      final uri = Uri.http('127.0.0.1:$port', '/', queryParams);
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
