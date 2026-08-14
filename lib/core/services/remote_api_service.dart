import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';
import 'package:dmx/core/services/logging_service.dart';
import '../utils/crypto_utils.dart';

class RemoteApiService {
  /// Fallback port used when parsing legacy single-line token files.
  /// Active server binds dynamically to port 0 (ephemeral).
  static const int _port = 37129;
  static HttpServer? _server;
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
      } catch (e) {
        LoggingService.logger('RemoteApiService').info(
          '[RemoteApiService] chmod on token dir skipped: $e',
        );
      }
    }

    _cachedTokenFilePath =
        dir.endsWith('/') ? '$dir$_tokenFileName' : '$dir/$_tokenFileName';
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

    try {
      // FIX(9): bind to port 0 so the OS assigns an ephemeral, guaranteed-free
      // port instead of a fixed port that a stray process could occupy. The
      // actual port is recorded in the token file for consumers.
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      await _writeTokenFile(_bearerToken!, _server!.port);
    } catch (e) {
      // Bind failed (rare with port 0) — discover any live primary through
      // its token file and heartbeat it; if alive, piggyback on it.
      final primary = await _readRemoteInfo();
      if (primary != null && await _isPrimaryAlive(primary.$2)) {
        debugPrint(
            'Remote API: existing server on port ${primary.$2} is alive');
        return;
      }
      // No live primary — delete stale token file and retry bind
      try {
        await File(await _tokenFilePath()).delete();
      } catch (e) {
        LoggingService.logger('RemoteApiService').info(
          '[RemoteApiService] deleting stale token file failed: $e',
        );
      }
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        await _writeTokenFile(_bearerToken!, _server!.port);
      } catch (retryError) {
        debugPrint('Remote API: retry bind also failed: $retryError');
        return;
      }
    }

    _server!.listen(
      (HttpRequest request) async {
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
          if (!timingSafeEqual(token, _bearerToken!)) {
            request.response.statusCode = 401;
            request.response.write(jsonEncode({'error': 'Invalid token'}));
            await request.response.close();
            return;
          }

          try {
            // Validate path to prevent path traversal attacks
            if (path.contains('..')) {
              request.response.statusCode = 400;
              request.response.write(jsonEncode({'error': 'Invalid path'}));
              await request.response.close();
              return;
            }

            if (path == '/api/tasks' && method == 'GET') {
              final tasks = await getTasks();
              request.response.write(jsonEncode(tasks));
            } else if (path.startsWith('/api/tasks/') &&
                path.endsWith('/pause') &&
                method == 'POST') {
              final segments = path.split('/');
              if (segments.length != 5) {
                request.response.statusCode = 400;
                request.response.write(
                  jsonEncode({'error': 'Invalid path structure'}),
                );
              } else {
                final id = segments[3];
                if (!_isValidTaskId(id)) {
                  request.response.statusCode = 400;
                  request.response.write(
                    jsonEncode({'error': 'Invalid task ID'}),
                  );
                } else {
                  await pauseTask(id);
                  request.response.write(jsonEncode({'ok': true}));
                }
              }
            } else if (path.startsWith('/api/tasks/') &&
                path.endsWith('/resume') &&
                method == 'POST') {
              final segments = path.split('/');
              if (segments.length != 5) {
                request.response.statusCode = 400;
                request.response.write(
                  jsonEncode({'error': 'Invalid path structure'}),
                );
              } else {
                final id = segments[3];
                if (!_isValidTaskId(id)) {
                  request.response.statusCode = 400;
                  request.response.write(
                    jsonEncode({'error': 'Invalid task ID'}),
                  );
                } else {
                  await resumeTask(id);
                  request.response.write(jsonEncode({'ok': true}));
                }
              }
            } else if (path.startsWith('/api/tasks/') &&
                path.endsWith('/delete') &&
                method == 'DELETE') {
              final segments = path.split('/');
              if (segments.length != 5) {
                request.response.statusCode = 400;
                request.response.write(
                  jsonEncode({'error': 'Invalid path structure'}),
                );
              } else {
                final id = segments[3];
                if (!_isValidTaskId(id)) {
                  request.response.statusCode = 400;
                  request.response.write(
                    jsonEncode({'error': 'Invalid task ID'}),
                  );
                } else {
                  await deleteTask(id);
                  request.response.write(jsonEncode({'ok': true}));
                }
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
          } catch (e) {
            LoggingService.logger('RemoteApiService').info(
              '[RemoteApiService] closing response failed: $e',
            );
          }
        } catch (outerError) {
          debugPrint('Remote API request listener error: $outerError');
          try {
            await request.response.close();
          } catch (e) {
            LoggingService.logger('RemoteApiService').info(
              '[RemoteApiService] closing response failed: $e',
            );
          }
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

  static final Lock _tokenFileLock = Lock();

  // FIX-S3: Token file management with permission restrictions
  static Future<void> _writeTokenFile(String token, int port) async {
    return _tokenFileLock.synchronized(() async {
      try {
        final path = await _tokenFilePath();
        // Format matches single_instance_service: "<token>\n<port>".
        await File(path).writeAsString('$token\n$port');
        if (!Platform.isWindows) {
          try {
            await Process.run('chmod', ['600', path]);
          } catch (e) {
            LoggingService.logger('RemoteApiService').info(
              '[RemoteApiService] chmod on token file skipped: $e',
            );
          }
        }
      } catch (e) {
        debugPrint('Remote API: failed to write token file: $e');
      }
    });
  }

  /// Reads (token, port) from the token file, falling back to the fixed
  /// [_port] for legacy single-line files.
  static Future<(String, int)?> _readRemoteInfo() async {
    try {
      final path = await _tokenFilePath();
      if (!await File(path).exists()) return null;
      final contents = (await File(path).readAsString()).trim();
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
      LoggingService.logger('RemoteApiService').info(
        '[RemoteApiService] reading token file failed, returning null: $e',
      );
      return null;
    }
  }

  /// TCP heartbeat: does something accept connections on [port]?
  static Future<bool> _isPrimaryAlive(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      );
      await socket.close();
      return true;
    } catch (e) {
      LoggingService.logger('RemoteApiService').info(
        '[RemoteApiService] primary heartbeat probe failed: $e',
      );
      return false;
    }
  }

  static void stop() {
    _server?.close(force: true);
    _server = null;
    _bearerToken = null;
  }
}
