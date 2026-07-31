import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class RemoteApiService {
  static HttpServer? _server;
  static const int _port = 37129;
  static String? _bearerToken;
  static String? _cachedTokenFilePath;

  static const _tokenFileName = '.xdm_remote_token';

  /// Path to the token file (app support directory).
  static Future<String> _tokenFilePath() async {
    if (_cachedTokenFilePath != null) return _cachedTokenFilePath!;
    String dir;
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null) {
        dir = '$appData/xdm';
      } else {
        dir = (await getApplicationSupportDirectory()).path;
      }
    } else if (Platform.isLinux || Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home != null) {
        dir = '$home/.config/xdm';
      } else {
        dir = (await getApplicationSupportDirectory()).path;
      }
    } else {
      dir = (await getApplicationSupportDirectory()).path;
    }

    final directory = Directory(dir);
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['700', dir]);
      } catch (_) {}
    }

    _cachedTokenFilePath = dir.endsWith('/')
        ? '$dir$_tokenFileName'
        : '$dir/$_tokenFileName';
    return _cachedTokenFilePath!;
  }

  static bool _isValidTaskId(String id) {
    if (id.isEmpty || id.length > 128) return false;
    if (RegExp(
      r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
    ).hasMatch(id)) {
      return true;
    }
    if (RegExp(r'^\d{10,20}_\d{1,10}$').hasMatch(id)) {
      return true;
    }
    return false;
  }

  static Future<void> start({
    required Future<List<Map<String, dynamic>>> Function() getTasks,
    required Future<void> Function(String id) pauseTask,
    required Future<void> Function(String id) resumeTask,
    required Future<void> Function(String id) deleteTask,
  }) async {
    if (kIsWeb ||
        (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS)) {
      return;
    }

    _bearerToken = _generateToken();
    await _writeTokenFile(_bearerToken!);

    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
    } catch (e) {
      // Bind failed — ping the existing server to check if it is still alive
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 3);
        final pingRequest = await client.getUrl(
          Uri.parse('http://127.0.0.1:$_port/api/health'),
        );
        pingRequest.headers.set('Authorization', 'Bearer ping');
        final pingResponse = await pingRequest.close();
        if (pingResponse.statusCode == 200) {
          // Server is alive — do nothing, piggyback on existing instance
          debugPrint('Remote API: existing server on port $_port is alive');
          return;
        }
      } catch (_) {
        // No response — delete stale token file and retry
        try {
          await File(await _tokenFilePath()).delete();
        } catch (_) {}
      }
      // Retry bind
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
      } catch (retryError) {
        debugPrint('Remote API: retry bind also failed: $retryError');
        return;
      }
    }

    _server!.listen(
      (request) async {
        try {
          final path = request.uri.path;
          final method = request.method;

          request.response.headers.contentType = ContentType.json;

          // Health check — always allowed without auth
          if (path == '/api/health' && method == 'GET') {
            request.response.write(jsonEncode({'ok': true}));
            await request.response.close();
            return;
          }

          // Require bearer token for all other endpoints
          final authHeader = request.headers.value('authorization');
          if (authHeader == null || !authHeader.startsWith('Bearer ')) {
            request.response.statusCode = 401;
            request.response.write(
              jsonEncode({'error': 'Missing or invalid authorization header'}),
            );
            await request.response.close();
            return;
          }
          final token = authHeader.substring(7).trim();
          if (!_timingSafeEqual(token, _bearerToken!)) {
            request.response.statusCode = 401;
            request.response.write(jsonEncode({'error': 'Invalid token'}));
            await request.response.close();
            return;
          }

          try {
            if (path == '/api/tasks' && method == 'GET') {
              final tasks = await getTasks();
              request.response.write(jsonEncode(tasks));
            } else if (path.startsWith('/api/tasks/') &&
                path.endsWith('/pause') &&
                method == 'POST') {
              final id = path.split('/')[3];
              if (!_isValidTaskId(id)) {
                request.response.statusCode = 400;
                request.response.write(
                  jsonEncode({'error': 'Invalid task ID'}),
                );
              } else {
                await pauseTask(id);
                request.response.write(jsonEncode({'ok': true}));
              }
            } else if (path.startsWith('/api/tasks/') &&
                path.endsWith('/resume') &&
                method == 'POST') {
              final id = path.split('/')[3];
              if (!_isValidTaskId(id)) {
                request.response.statusCode = 400;
                request.response.write(
                  jsonEncode({'error': 'Invalid task ID'}),
                );
              } else {
                await resumeTask(id);
                request.response.write(jsonEncode({'ok': true}));
              }
            } else if (path.startsWith('/api/tasks/') &&
                path.endsWith('/delete') &&
                method == 'DELETE') {
              final id = path.split('/')[3];
              if (!_isValidTaskId(id)) {
                request.response.statusCode = 400;
                request.response.write(
                  jsonEncode({'error': 'Invalid task ID'}),
                );
              } else {
                await deleteTask(id);
                request.response.write(jsonEncode({'ok': true}));
              }
            } else {
              request.response.statusCode = 404;
              request.response.write(jsonEncode({'error': 'Not found'}));
            }
          } catch (e) {
            request.response.statusCode = 500;
            request.response.write(jsonEncode({'error': e.toString()}));
          }
          try {
            await request.response.close();
          } catch (_) {}
        } catch (outerError) {
          debugPrint('Remote API request listener error: $outerError');
          try {
            await request.response.close();
          } catch (_) {}
        }
      },
      onError: (Object err) {
        debugPrint('Remote API server stream error: $err');
      },
    );
  }

  static String _generateToken() {
    final rand = Random.secure();
    final bytes = List<int>.generate(32, (_) => rand.nextInt(256));
    return base64Url.encode(bytes);
  }

  static Future<void> _writeTokenFile(String token) async {
    try {
      final path = await _tokenFilePath();
      await File(path).writeAsString(token);
      if (!Platform.isWindows) {
        try {
          await Process.run('chmod', ['600', path]);
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Remote API: failed to write token file: $e');
    }
  }

  /// Timing-safe string comparison to prevent timing side-channel attacks.
  /// Pads both inputs to [_maxTokenLength] so that length mismatches do not
  /// short-circuit and leak the token length.
  static const int _maxTokenLength = 256;

  static bool _timingSafeEqual(String a, String b) {
    // If either string exceeds the expected max length, they cannot match.
    // The length check itself is O(1) and safe because legitimate tokens
    // are always well under [_maxTokenLength].
    if (a.length > _maxTokenLength || b.length > _maxTokenLength) return false;
    final paddedA = a.padRight(_maxTokenLength, '\x00');
    final paddedB = b.padRight(_maxTokenLength, '\x00');
    int result = 0;
    for (int i = 0; i < _maxTokenLength; i++) {
      result |= paddedA.codeUnitAt(i) ^ paddedB.codeUnitAt(i);
    }
    return result == 0;
  }

  static void stop() {
    _server?.close(force: true);
    _server = null;
    _bearerToken = null;
  }
}
