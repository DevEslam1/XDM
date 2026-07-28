import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class RemoteApiService {
  static HttpServer? _server;
  static const int _port = 37129;
  
  static Future<void> start({
    required Future<List<Map<String, dynamic>>> Function() getTasks,
    required Future<void> Function(String id) pauseTask,
    required Future<void> Function(String id) resumeTask,
    required Future<void> Function(String id) deleteTask,
  }) async {
    if (kIsWeb || (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS)) return;
    
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
    _server!.listen((request) async {
      final path = request.uri.path;
      final method = request.method;
      
      request.response.headers.contentType = ContentType.json;
      
      try {
        if (path == '/api/tasks' && method == 'GET') {
          final tasks = await getTasks();
          request.response.write(jsonEncode(tasks));
        } else if (path.startsWith('/api/tasks/') && path.endsWith('/pause') && method == 'POST') {
          final id = path.split('/')[3];
          await pauseTask(id);
          request.response.write(jsonEncode({'ok': true}));
        } else if (path.startsWith('/api/tasks/') && path.endsWith('/resume') && method == 'POST') {
          final id = path.split('/')[3];
          await resumeTask(id);
          request.response.write(jsonEncode({'ok': true}));
        } else if (path.startsWith('/api/tasks/') && path.endsWith('/delete') && method == 'DELETE') {
          final id = path.split('/')[3];
          await deleteTask(id);
          request.response.write(jsonEncode({'ok': true}));
        } else {
          request.response.statusCode = 404;
          request.response.write(jsonEncode({'error': 'Not found'}));
        }
      } catch (e) {
        request.response.statusCode = 500;
        request.response.write(jsonEncode({'error': e.toString()}));
      }
      await request.response.close();
    });
  }
  
  static void stop() {
    _server?.close(force: true);
    _server = null;
  }
}
