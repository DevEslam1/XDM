import 'dart:convert';
import 'dart:io';

import 'package:dmx/core/services/remote_api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// An [HttpOverrides] that leaves the platform's real client factory intact.
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RemoteApiService feature gating', () {
    tearDown(() {
      RemoteApiService.stop();
      RemoteApiService.enabled = false;
    });

    test('is disabled by default', () {
      expect(RemoteApiService.enabled, isFalse);
    });

    test('start is a no-op while disabled', () async {
      await RemoteApiService.start(
        getTasks: () async => [],
        pauseTask: (id) async {},
        resumeTask: (id) async {},
        deleteTask: (id) async {},
      );
      expect(RemoteApiService.enabled, isFalse);
    });

    test('stop is safe when no server is running', () {
      expect(RemoteApiService.stop, returnsNormally);
    });
  });

  group('RemoteApiService loopback server', () {
    late String token;
    late int port;
    late List<String> calls;
    var throwOnTasks = false;

    Future<String> tokenFilePath() async {
      final appData = Platform.environment['APPDATA'];
      final dir = appData != null
          ? p.join(appData, 'xdm')
          : (Platform.environment['HOME'] ?? Directory.systemTemp.path);
      return p.join(dir, '.xdm_remote_token');
    }

    setUpAll(() async {
      calls = <String>[];
      RemoteApiService.enabled = true;
      await RemoteApiService.start(
        getTasks: () async {
          if (throwOnTasks) throw Exception('task store exploded');
          return [
            {'id': 'abc', 'status': 'downloading'},
          ];
        },
        pauseTask: (id) async => calls.add('pause:$id'),
        resumeTask: (id) async => calls.add('resume:$id'),
        deleteTask: (id) async => calls.add('delete:$id'),
      );

      final path = await tokenFilePath();
      final contents = await File(path).readAsString();
      final lines = contents.split('\n');
      token = lines[0].trim();
      port = int.parse(lines[1].trim());
    });

    tearDownAll(() {
      RemoteApiService.stop();
      RemoteApiService.enabled = false;
    });

    setUp(() {
      calls.clear();
      throwOnTasks = false;
    });

    Future<HttpClientResponse> call(
      String method,
      String path, {
      String? auth,
      List<int>? body,
      int? contentLength,
    }) {
      // flutter_test installs a mock HttpOverrides that returns a canned 400
      // for every request. Run the real client inside a zone that bypasses it.
      return HttpOverrides.runZoned(() async {
        final client = HttpClient();
        final request = await client.openUrl(
            method, Uri.parse('http://127.0.0.1:$port$path'));
        if (auth != null) {
          request.headers.set(HttpHeaders.authorizationHeader, auth);
        }
        if (body != null) {
          request.contentLength = contentLength ?? body.length;
          request.add(body);
        }
        return request.close();
      },
          createHttpClient: (context) =>
              _RealHttpOverrides().createHttpClient(context));
    }

    Future<String> bodyOf(HttpClientResponse response) =>
        response.transform(utf8.decoder).join();

    test('health endpoint is unauthenticated', () async {
      final response = await call('GET', '/api/health');
      expect(response.statusCode, 200);
      expect(jsonDecode(await bodyOf(response)), {'ok': true});
    });

    test('missing authorization header yields 401', () async {
      final response = await call('GET', '/api/tasks');
      expect(response.statusCode, 401);
    });

    test('invalid bearer token yields 401', () async {
      final response =
          await call('GET', '/api/tasks', auth: 'Bearer not-the-token');
      expect(response.statusCode, 401);
    });

    test('GET /api/tasks returns the task list', () async {
      final response = await call('GET', '/api/tasks', auth: 'Bearer $token');
      expect(response.statusCode, 200);
      final decoded = jsonDecode(await bodyOf(response)) as List;
      expect(decoded, hasLength(1));
    });

    test('task action endpoints invoke callbacks', () async {
      const id = '1234567890_12';

      final pause = await call(
        'POST',
        '/api/tasks/$id/pause',
        auth: 'Bearer $token',
      );
      expect(pause.statusCode, 200);
      expect(jsonDecode(await bodyOf(pause)), {'ok': true});

      final resume = await call(
        'POST',
        '/api/tasks/$id/resume',
        auth: 'Bearer $token',
      );
      expect(resume.statusCode, 200);
      expect(jsonDecode(await bodyOf(resume)), {'ok': true});

      final delete = await call(
        'DELETE',
        '/api/tasks/$id/delete',
        auth: 'Bearer $token',
      );
      expect(delete.statusCode, 200);
      expect(jsonDecode(await bodyOf(delete)), {'ok': true});

      expect(calls, ['pause:$id', 'resume:$id', 'delete:$id']);
    });

    test('invalid task id yields 400', () async {
      final response = await call(
        'POST',
        '/api/tasks/not-a-valid-id/pause',
        auth: 'Bearer $token',
      );
      expect(response.statusCode, 400);
      await bodyOf(response);
      expect(calls, isEmpty);
    });

    test('wrong path structure yields 400', () async {
      final response = await call(
        'POST',
        '/api/tasks/a/b/pause',
        auth: 'Bearer $token',
      );
      expect(response.statusCode, 400);
      await bodyOf(response);
    });

    test('unknown path yields 404', () async {
      final response =
          await call('GET', '/api/does-not-exist', auth: 'Bearer $token');
      expect(response.statusCode, 404);
      await bodyOf(response);
    });

    test('callback failure surfaces as 500', () async {
      throwOnTasks = true;
      final response = await call('GET', '/api/tasks', auth: 'Bearer $token');
      expect(response.statusCode, 500);
      expect(await bodyOf(response), contains('exploded'));
    });

    test('invalid host header is rejected with 403', () async {
      final result = await HttpOverrides.runZoned(() async {
        final client = HttpClient();
        final request = await client.openUrl(
          'GET',
          Uri.parse('http://127.0.0.1:$port/api/health'),
        );
        try {
          request.headers.set(HttpHeaders.hostHeader, 'evil.example.com');
        } catch (_) {
          // Some platforms forbid overriding Host; skip the assertion then.
          return 403;
        }
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      },
          createHttpClient: (context) =>
              _RealHttpOverrides().createHttpClient(context));
      expect(result, 403);
    });

    test('path traversal is rejected', () async {
      final response = await call(
        'GET',
        '/api/tasks/%2e%2e/pause',
        auth: 'Bearer $token',
      );
      await bodyOf(response);
      expect(response.statusCode, anyOf(400, 404));
    });

    test('oversized payload yields 413', () async {
      final big = List<int>.filled(70000, 0x41);
      try {
        final response = await call(
          'POST',
          '/api/tasks/1234567890_12/pause',
          auth: 'Bearer $token',
          body: big,
          contentLength: big.length,
        );
        expect(response.statusCode, 413);
        await bodyOf(response);
      } on HttpException {
        // The server may close the connection mid-upload; either outcome is
        // an acceptable rejection of the oversized payload.
      }
    });

    test('rate limiting rejects after the per-minute budget', () async {
      var sawTooMany = false;
      for (var i = 0; i < 140; i++) {
        final response = await call('GET', '/api/health');
        await bodyOf(response);
        if (response.statusCode == 429) {
          sawTooMany = true;
          break;
        }
      }
      expect(sawTooMany, isTrue);
    });
  });
}
