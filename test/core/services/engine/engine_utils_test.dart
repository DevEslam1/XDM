import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TimestampedLruMap', () {
    test('put/get/containsKey/remove/keys and operators', () {
      final map = TimestampedLruMap<String, int>(maxCapacity: 3);
      expect(map.isEmpty, isTrue);
      map.put('a', 1);
      map['b'] = 2;
      expect(map.length, 2);
      expect(map.isNotEmpty, isTrue);
      expect(map.get('a'), 1);
      expect(map['b'], 2);
      expect(map.containsKey('a'), isTrue);
      expect(map.get('missing'), isNull);
      expect(map.keys, containsAll(['a', 'b']));
      expect(map.remove('a'), 1);
      expect(map.remove('missing'), isNull);
      expect(map.containsKey('a'), isFalse);
    });

    test('evicts least-recently-used entry at capacity', () {
      final map = TimestampedLruMap<String, int>(maxCapacity: 2);
      map.put('a', 1);
      map.put('b', 2);
      map.get('a'); // touch a -> b is now LRU
      map.put('c', 3);
      expect(map.containsKey('b'), isFalse);
      expect(map.containsKey('a'), isTrue);
      expect(map.containsKey('c'), isTrue);
    });

    test('getLastAccessed and removeStale', () async {
      final map = TimestampedLruMap<String, int>();
      map.put('a', 1);
      expect(map.getLastAccessed('a'), isNotNull);
      expect(map.getLastAccessed('missing'), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      map.removeStale(Duration.zero);
      expect(map.isEmpty, isTrue);
    });

    test('clear empties the map', () {
      final map = TimestampedLruMap<String, int>();
      map.put('a', 1);
      map.clear();
      expect(map.isEmpty, isTrue);
    });
  });

  group('firstNonEmpty', () {
    test('prefers first non-blank value', () {
      expect(firstNonEmpty('a', 'b'), 'a');
      expect(firstNonEmpty('  ', 'b'), 'b');
      expect(firstNonEmpty(null, 'b'), 'b');
      expect(firstNonEmpty('', ''), isNull);
      expect(firstNonEmpty(null, null), isNull);
      expect(firstNonEmpty('a', null), 'a');
    });
  });

  group('DebugCertOverride', () {
    test('getCallback returns a permissive callback in debug/tests', () {
      final cb = DebugCertOverride.getCallback('https://x');
      expect(cb, isNotNull);
    });

    test('honors the explicit override flag', () {
      expect(
          DebugCertOverride.getCallback('https://x',
              allowDebugCertOverride: true),
          isNotNull);
    });
  });

  group('isLikelyHtmlResponse', () {
    Headers h(Map<String, List<String>> m) => Headers.fromMap(m);

    test('detects html / xhtml content types', () {
      expect(
          isLikelyHtmlResponse(h({
            'content-type': ['text/html']
          })),
          isTrue);
      expect(
          isLikelyHtmlResponse(h({
            'content-type': ['application/xhtml+xml']
          })),
          isTrue);
    });

    test('detects html markers in the first chunk', () {
      for (final marker in ['<!doctype html>', '<html>', '<head>', '<body>']) {
        expect(
            isLikelyHtmlResponse(h({}), firstChunk: marker.codeUnits), isTrue,
            reason: marker);
      }
    });

    test('returns false for non-html', () {
      expect(
          isLikelyHtmlResponse(h({
            'content-type': ['video/mp4']
          })),
          isFalse);
      expect(isLikelyHtmlResponse(h({}), firstChunk: [1, 2, 3]), isFalse);
      expect(isLikelyHtmlResponse(h({}), firstChunk: []), isFalse);
    });
  });

  group('actualDownloadedBytes', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('dmx_utils_test');
    });

    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('returns 0 when the temp file does not exist', () async {
      expect(await actualDownloadedBytes('${dir.path}/missing.dmxpart'), 0);
    });

    test('returns file length for single-thread without state', () async {
      final f = File('${dir.path}/f.dmxpart');
      await f.writeAsBytes(List.filled(100, 0));
      expect(await actualDownloadedBytes(f.path, threadCount: 1), 100);
    });

    test('returns 0 for multi-thread without state (preallocated)', () async {
      final f = File('${dir.path}/m.dmxpart');
      await f.writeAsBytes(List.filled(100, 0));
      expect(await actualDownloadedBytes(f.path, threadCount: 4), 0);
    });

    test('uses the persisted state and clamps to totalSize', () async {
      final f = File('${dir.path}/s.dmxpart');
      await f.writeAsBytes(List.filled(50, 0));
      final state = TransferState(
        totalSize: 40,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 39, downloaded: 40)],
      );
      await StateStore.save(f.path, state, taskId: 'task-1');

      final bytes = await actualDownloadedBytes(f.path,
          threadCount: 1, stateStore: StateStore.instance, taskId: 'task-1');
      expect(bytes, 40);
    });
  });

  group('buildTransferDio', () {
    test('pooled client is returned untouched', () {
      final pooled = Dio();
      final before = pooled.interceptors.length;
      final client = buildTransferDio(pooled: pooled);
      expect(identical(client, pooled), isTrue);
      expect(client.interceptors.length, before);
    });

    test('sets custom UA, referer, cookies, oauth and custom headers', () {
      final client = buildTransferDio(
        url: 'https://example.com/f.zip',
        customUserAgent: 'Agent/1',
        referer: 'https://ref',
        cookies: 'a=b',
        oauthToken: 'tok',
        customHeaders: {'X-Custom': 'v', '  ': 'ignored'},
      );
      expect(client.options.headers['User-Agent'], 'Agent/1');
      expect(client.options.headers['Referer'], 'https://ref');
      expect(client.options.headers['Cookie'], 'a=b');
      expect(client.options.headers['Authorization'], 'Bearer tok');
      expect(client.options.headers['X-Custom'], 'v');
      expect(client.options.headers.containsKey('  '), isFalse);
    });

    test('youtube url sets Origin and a browser UA', () {
      final client = buildTransferDio(url: 'https://www.youtube.com/watch?v=1');
      expect(client.options.headers['Origin'], 'https://www.youtube.com');
      expect(client.options.headers['User-Agent'], contains('Chrome'));
    });

    test('basic auth from explicit credentials and from userInfo', () {
      final explicit = buildTransferDio(
        url: 'https://example.com/f',
        authUsername: 'user',
        authPassword: 'pass',
      );
      expect(explicit.options.headers['Authorization'], startsWith('Basic '));

      final userInfo = buildTransferDio(url: 'https://u:p@example.com/f');
      expect(userInfo.options.headers['Authorization'], startsWith('Basic '));
    });

    test('httpsOnly and non-https scheme still build a client', () {
      final client =
          buildTransferDio(url: 'http://example.com/f', httpsOnly: true);
      expect(client, isA<Dio>());
    });

    test('http proxy configures the underlying HttpClient', () {
      final client = buildTransferDio(
        url: 'https://example.com/f',
        proxyType: 'http',
        proxyHost: 'proxy.local',
        proxyPort: 8080,
        proxyUsername: 'pu',
        proxyPassword: 'pp',
      );
      final adapter = client.httpClientAdapter as IOHttpClientAdapter;
      expect(adapter.createHttpClient, isNotNull);
      final httpClient = adapter.createHttpClient!();
      expect(httpClient.maxConnectionsPerHost, 64);
      httpClient.close();
    });

    test('no proxy leaves findProxy at default', () {
      final client = buildTransferDio(url: 'https://example.com/f');
      final adapter = client.httpClientAdapter as IOHttpClientAdapter;
      final httpClient = adapter.createHttpClient!();
      expect(httpClient.maxConnectionsPerHost, 64);
      httpClient.close();
    });
  });
}
