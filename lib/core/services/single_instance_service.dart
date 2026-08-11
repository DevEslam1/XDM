import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'logging_service.dart';
import '../utils/crypto_utils.dart';
import '../utils/url_utils.dart';

class SingleInstanceService {
  static final SingleInstanceService _instance =
      SingleInstanceService._internal();
  factory SingleInstanceService() => _instance;
  SingleInstanceService._internal();

  @visibleForTesting
  factory SingleInstanceService.createForTest({File? customTokenFile}) {
    final service = SingleInstanceService._internal();
    service._overrideTokenFile = customTokenFile;
    return service;
  }

  File? _overrideTokenFile;

  static final _log = LoggingService.logger('SingleInstanceService');
  static const int _port = 37128;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _serverSubscription;
  Timer? _heartbeatTimer;
  void Function(String url)? _onUrlListener;
  String? _initialUrl;
  String? _securityToken;

  String? get initialUrl => _initialUrl;

  // FIX: Use p.join() for cross-platform path construction
  File get _tokenFile {
    if (_overrideTokenFile != null) return _overrideTokenFile!;
    if (Platform.isLinux || Platform.isMacOS) {
      final userHome = Platform.environment['HOME'];
      if (userHome != null && userHome.isNotEmpty) {
        return File(p.join(userHome, '.config', 'xdm', 'xdm_instance_$_port.token'));
      }
      return File('/nonexistent/xdm_instance_$_port.token');
    } else if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ??
          Platform.environment['LOCALAPPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return File(p.join(appData, 'xdm', 'xdm_instance_$_port.token'));
      }
      return File(p.join('C:', 'nonexistent', 'xdm_instance_$_port.token'));
    }
    return File('/nonexistent/xdm_instance_$_port.token');
  }

  Future<void> _ensureTokenDirectory() async {
    try {
      final file = _tokenFile;
      final parentDir = file.parent;
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }
      if ((Platform.isLinux || Platform.isMacOS) &&
          _overrideTokenFile == null) {
        try {
          await Process.run('chmod', ['700', parentDir.path]);
        } catch (e) {
          _log.info('[SingleInstanceService] chmod on token dir skipped: $e');
        }
      }
    } catch (e) {
      _log.severe('Failed to create secure token directory', e);
    }
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
    await _ensureTokenDirectory();

    final primaryInfo = await _readTokenFile();
    if (primaryInfo != null) {
      final (token, port, timestamp) = primaryInfo;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final isHeartbeatStale = timestamp > 0 && (nowMs - timestamp > 90000);

      if (!isHeartbeatStale && await _isPrimaryAlive(port)) {
        if (candidateUrl != null && candidateUrl.isNotEmpty) {
          await _forwardTo(token, port, candidateUrl);
        }
        return false;
      }
    }

    try {
      if (await _tokenFile.exists()) await _tokenFile.delete();
    } catch (e) {
      _log.info('[SingleInstanceService] deleting stale token file failed: $e');
    }

    try {
      await _startServer(candidateUrl);
      return true;
    } catch (e) {
      _log.warning('Init error, treating as primary', e);
      _initialUrl = candidateUrl;
      return true;
    }
  }

  Future<void> _startServer(String? candidateUrl) async {
    await _ensureTokenDirectory();
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port)
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      _log.warning(
        'Bind to fixed port $_port failed/timed out, attempting port 0: $e',
      );
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
            .timeout(const Duration(seconds: 3));
      } catch (e2) {
        _log.severe('Failed to bind server within timeout: $e2');
        _initialUrl = candidateUrl;
        return;
      }
    }

    _initialUrl = candidateUrl;
    await _writeTokenFileWithLock();
    _startHeartbeatTimer();

    _serverSubscription = _server?.listen((HttpRequest request) async {
      try {
        final tokenParam = request.uri.queryParameters['token'];
        if (tokenParam == null ||
            !timingSafeEqual(tokenParam, _securityToken!)) {
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

  void _startHeartbeatTimer() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      await _writeTokenFileWithLock();
    });
  }

  Future<void> _writeTokenFileWithLock() async {
    if (_securityToken == null) return;
    try {
      await _ensureTokenDirectory();
      final file = _tokenFile;
      final contents =
          '$_securityToken\n${_server?.port ?? _port}\n${DateTime.now().millisecondsSinceEpoch}';

      final raf = await file.open(mode: FileMode.write);
      try {
        await raf.lock(FileLock.exclusive);
        await raf.writeString(contents);
        await raf.flush();
      } finally {
        await raf.unlock();
        await raf.close();
      }
    } catch (e) {
      _log.warning('Atomic write with lock failed: $e');
    }
  }

  Future<(String, int, int)?> _readTokenFile() async {
    try {
      final file = _tokenFile;
      if (!await file.exists()) return null;

      String contents = '';
      final raf = await file.open(mode: FileMode.read);
      try {
        await raf.lock(FileLock.shared);
        final length = await raf.length();
        final bytes = await raf.read(length);
        contents = utf8.decode(bytes).trim();
      } finally {
        await raf.unlock();
        await raf.close();
      }

      if (contents.isEmpty) return null;
      final lines = contents.split('\n');
      final token = lines.first.trim();
      if (token.isEmpty) return null;

      int port = _port;
      if (lines.length >= 2) {
        final parsed = int.tryParse(lines[1].trim());
        if (parsed != null && parsed > 0) port = parsed;
      }

      int timestamp = 0;
      if (lines.length >= 3) {
        final parsedTs = int.tryParse(lines[2].trim());
        if (parsedTs != null) timestamp = parsedTs;
      }

      return (token, port, timestamp);
    } catch (e) {
      _log.info(
        '[SingleInstanceService] reading token file failed: $e',
      );
      return null;
    }
  }

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
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
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