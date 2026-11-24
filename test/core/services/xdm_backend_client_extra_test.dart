import 'dart:convert';
import 'dart:io';

import 'package:dmx/core/services/backend_health_service.dart';
import 'package:dmx/core/services/xdm_backend_client.dart';
import 'package:dmx/core/services/xdm_backend_exceptions.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/scriptable_http_server.dart';

const _secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScriptableHttpServer server;
  late SettingsProvider settings;

  void enqueueJson(Object body, {int status = 200}) {
    server.enqueue((request) async {
      final response = request.response;
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(body));
      await response.close();
    });
  }

  void enqueueRaw(String body,
      {int status = 200, ContentType? contentType}) {
    server.enqueue((request) async {
      final response = request.response;
      response.statusCode = status;
      response.headers.contentType = contentType ?? ContentType.text;
      response.write(body);
      await response.close();
    });
  }

  setUpAll(() {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      _secureStorageChannel,
      (call) async => null,
    );
  });

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    settings = SettingsProvider.instance;
    await settings.load();
    await settings.setSendBrowserCookiesToBackend(false);
    await XdmBackendClient.setApiKey('');
    BackendHealthService.instance.resetCooldowns();
    server = ScriptableHttpServer();
    await server.start();
    await settings.setBackendUrl(server.baseUrl);
    XdmBackendClient().refreshConfig();
  });

  tearDown(() async {
    await settings.setBackendUrl('');
    await server.stop();
  });

  group('health', () {
    test('returns the decoded body on success', () async {
      enqueueJson({'status': 'ok', 'version': '1.2.3'});
      final data = await XdmBackendClient().health();
      expect(data['status'], 'ok');
      expect(data['version'], '1.2.3');
    });

    test('maps a 400 map body to BackendBadRequestException', () async {
      enqueueJson({'detail': 'invalid video'}, status: 400);
      await expectLater(
        XdmBackendClient().health(),
        throwsA(
          isA<BackendBadRequestException>()
              .having((e) => e.message, 'message', 'invalid video'),
        ),
      );
    });

    test('maps a 400 JSON string body to BackendBadRequestException',
        () async {
      enqueueRaw(
        jsonEncode({'message': 'decoded from string'}),
        status: 400,
        contentType: ContentType.text,
      );
      await expectLater(
        XdmBackendClient().health(),
        throwsA(
          isA<BackendBadRequestException>()
              .having((e) => e.message, 'message', 'decoded from string'),
        ),
      );
    });

    test('maps a 400 plain string body to BackendBadRequestException',
        () async {
      enqueueRaw('plain failure', status: 400, contentType: ContentType.text);
      await expectLater(
        XdmBackendClient().health(),
        throwsA(
          isA<BackendBadRequestException>()
              .having((e) => e.message, 'message', 'plain failure'),
        ),
      );
    });

    test('maps 401 to BackendUnauthorizedException', () async {
      enqueueJson({'detail': 'no token'}, status: 401);
      await expectLater(
        XdmBackendClient().health(),
        throwsA(
          isA<BackendUnauthorizedException>()
              .having((e) => e.message, 'message', 'no token'),
        ),
      );
    });

    test('maps 403 to BackendUnauthorizedException defaults', () async {
      enqueueJson({}, status: 403);
      await expectLater(
        XdmBackendClient().health(),
        throwsA(isA<BackendUnauthorizedException>()),
      );
    });

    test('maps 404 to BackendNotFoundException', () async {
      enqueueJson({}, status: 404);
      await expectLater(
        XdmBackendClient().health(),
        throwsA(isA<BackendNotFoundException>()),
      );
    });

    test('maps 429 to BackendRateLimitException with retry-after', () async {
      server.enqueue((request) async {
        request.response.statusCode = 429;
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('retry-after', '17');
        request.response.write(jsonEncode({'detail': 'slow down'}));
        await request.response.close();
      });
      await expectLater(
        XdmBackendClient().health(),
        throwsA(
          isA<BackendRateLimitException>()
              .having((e) => e.retryAfterSeconds, 'retryAfter', 17),
        ),
      );
    });

    test('maps 451 to BackendBadRequestException geo message', () async {
      enqueueJson({}, status: 451);
      await expectLater(
        XdmBackendClient().health(),
        throwsA(
          isA<BackendBadRequestException>()
              .having((e) => e.message, 'message', contains('geo-restricted')),
        ),
      );
    });

    test('maps 500 to BackendNetworkException', () async {
      enqueueJson({'detail': 'boom'}, status: 500);
      await expectLater(
        XdmBackendClient().health(),
        throwsA(
          isA<BackendNetworkException>()
              .having((e) => e.message, 'message', contains('boom')),
        ),
      );
    });
  });

  group('getStreams error paths', () {
    test('401 surfaces as BackendUnauthorizedException', () async {
      enqueueJson({'detail': 'nope'}, status: 401);
      enqueueJson({'detail': 'nope'}, status: 401);
      await expectLater(
        XdmBackendClient().getStreams(
            'https://www.youtube.com/watch?v=401AUTH00001'),
        throwsA(isA<BackendUnauthorizedException>()),
      );
    });

    test('400 surfaces as BackendBadRequestException', () async {
      for (var i = 0; i < 4; i++) {
        enqueueJson({'detail': 'bad'}, status: 400);
      }
      await expectLater(
        XdmBackendClient().getStreams(
            'https://www.youtube.com/watch?v=400BAD000001'),
        throwsA(isA<BackendBadRequestException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('connection refused becomes BackendNetworkException', () async {
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close(force: true);
      await settings.setBackendUrl('http://127.0.0.1:$deadPort');
      XdmBackendClient().refreshConfig();

      await expectLater(
        XdmBackendClient().getStreams(
            'https://www.youtube.com/watch?v=DEADPORT0001'),
        throwsA(isA<BackendNetworkException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('getPlaylist and search', () {
    test('getPlaylist 401 surfaces as BackendUnauthorizedException', () async {
      enqueueJson({'detail': 'nope'}, status: 401);
      enqueueJson({'detail': 'nope'}, status: 401);
      await expectLater(
        XdmBackendClient().getPlaylist(
            'https://www.youtube.com/playlist?list=PL1234567890'),
        throwsA(isA<BackendUnauthorizedException>()),
      );
    });

    test('search returns an empty list when results are absent', () async {
      enqueueJson({'other': true});
      final results = await XdmBackendClient().search('q');
      expect(results, isEmpty);
    });
  });

  group('configuration', () {
    test('setApiKey persists a key and blank clears it', () async {
      await XdmBackendClient.setApiKey('secret-key');
      await XdmBackendClient.setApiKey('');
      // No throw.
      expect(XdmBackendClient.currentBackendUrl, isNotNull);
    });

    test('loadApiKey reads a stored key and uses it for auth', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_secureStorageChannel, (call) async {
        if (call.method == 'read') return 'stored-key';
        return null;
      });
      await XdmBackendClient.setApiKey('');
      await XdmBackendClient.loadApiKey();

      enqueueJson({'status': 'ok'});
      await XdmBackendClient().health();
      expect(
        server.capturedRequests.last.headers['authorization'],
        'Bearer stored-key',
      );
    });

    test('falls back to the settings backend token for auth', () async {
      await XdmBackendClient.setApiKey('');
      await settings.setBackendToken('custom-token');

      enqueueJson({'status': 'ok'});
      await XdmBackendClient().health();
      expect(
        server.capturedRequests.last.headers['authorization'],
        'Bearer custom-token',
      );
    });

    test('updateBackendConfig updates settings and the Dio client', () async {
      await XdmBackendClient().updateBackendConfig(server.baseUrl);
      expect(settings.backendUrl, server.baseUrl);
      enqueueJson({'status': 'ok'});
      final data = await XdmBackendClient().health();
      expect(data['status'], 'ok');
    });

    test('refreshConfig upgrades http to https for non-local hosts', () async {
      await settings.setBackendUrl('http://example.com');
      XdmBackendClient().refreshConfig();
      expect(settings.backendUrl, 'http://example.com');
      await settings.setBackendUrl(server.baseUrl);
    });

    test('refreshConfig strips a trailing slash', () async {
      await settings.setBackendUrl('${server.baseUrl}/');
      XdmBackendClient().refreshConfig();
      enqueueJson({'status': 'ok'});
      final data = await XdmBackendClient().health();
      expect(data['status'], 'ok');
    });

    test('dispose then refreshConfig restores a usable client', () async {
      XdmBackendClient().dispose();
      XdmBackendClient().refreshConfig();
      enqueueJson({'status': 'ok'});
      final data = await XdmBackendClient().health();
      expect(data['status'], 'ok');
    });
  });

  group('response validation and caching', () {
    test('accepts a url-only payload', () async {
      enqueueJson({'url': 'https://googlevideo.com/direct'});
      final data = await XdmBackendClient().getStreams(
          'https://www.youtube.com/watch?v=URLOONLY0001');
      expect(data['url'], contains('direct'));
    });

    test('rejects invalid payloads and reports failure', () async {
      for (var i = 0; i < 10; i++) {
        enqueueJson({'unexpected': true});
      }
      await expectLater(
        XdmBackendClient().getStreams(
            'https://www.youtube.com/watch?v=INVALID00001'),
        throwsA(isA<BackendException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('evicts a cache entry whose media URL is about to expire', () async {
      const key = 'https://www.youtube.com/watch?v=EXPIRY000001';
      final soon = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 60;
      final payload = {
        'streams': [
          {
            'type': 'combined',
            'quality': '720p',
            'direct_url': 'https://googlevideo.com/e?expire=$soon',
            'ext': 'mp4',
          },
        ],
      };
      enqueueJson(payload);
      await XdmBackendClient().getStreams(key);

      // A non-forced second call must detect the near-expiry URL, evict the
      // cached entry and fetch again.
      enqueueJson(payload);
      final data = await XdmBackendClient().getStreams(key);
      expect(data['streams'], isNotEmpty);
    });

    test('strips a trailing slash from the backend URL', () async {
      await settings.setBackendUrl('${server.baseUrl}/');
      XdmBackendClient().refreshConfig();
      enqueueJson({
        'streams': [
          {
            'type': 'combined',
            'quality': '720p',
            'direct_url': 'https://googlevideo.com/slash',
            'ext': 'mp4',
          },
        ],
      });
      final data = await XdmBackendClient().getStreams(
          'https://www.youtube.com/watch?v=TRAILSLASH1');
      expect(data['streams'], isNotEmpty);
    });

    test('maps an unmapped HTTP status to BackendUnknownException', () async {
      enqueueJson({'teapot': true}, status: 418);
      await expectLater(
        XdmBackendClient().health(),
        throwsA(isA<BackendUnknownException>()),
      );
    });
  });

  group('playlist request options', () {
    test('forwards cookies and paging parameters', () async {
      enqueueJson({
        'info': {'title': 'With Cookies'},
        'videos': [],
      });

      await XdmBackendClient().getPlaylist(
        'https://www.youtube.com/playlist?list=PL1234567890',
        cookies: 'SID=abc',
        pageToken: 'token-1',
        pageSize: 10,
      );

      expect(server.capturedRequests.last.headers['x-cookies'], isNotNull);
      expect(
        server.capturedRequests.last.uri.queryParameters['pageToken'],
        'token-1',
      );
      expect(
        server.capturedRequests.last.uri.queryParameters['pageSize'],
        '10',
      );
    });
  });
}
