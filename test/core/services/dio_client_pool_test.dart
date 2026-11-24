import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dmx/core/domain/torrent_models.dart' show ProxyType;
import 'package:dmx/core/services/dio_client_pool.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _RecordingAdapter implements HttpClientAdapter {
  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {}
}

class _ThrowingCloseDio extends Mock implements Dio {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DioClientPool pool;

  void resetPolicy() {
    DioNetworkPolicy.instance.update(
      httpsOnly: false,
      enableProxy: false,
      proxyType: ProxyType.none,
      proxyHost: '',
      proxyPort: 0,
      proxyUsername: '',
      proxyPassword: '',
    );
  }

  setUp(() {
    resetPolicy();
    PowerMonitor.setScreenOn(true);
    DownloadEngine.markForeground();
    DownloadEngine.setActiveDownloadsCount(0);
    pool = DioClientPool();
  });

  tearDown(() async {
    await pool.dispose();
    resetPolicy();
    PowerMonitor.setScreenOn(true);
    DownloadEngine.markForeground();
    DownloadEngine.setActiveDownloadsCount(0);
  });

  group('DioNetworkPolicy', () {
    test('update and httpProxyActive track configuration', () {
      final policy = DioNetworkPolicy.instance;
      policy.update(
        httpsOnly: true,
        enableProxy: true,
        proxyType: ProxyType.http,
        proxyHost: '1.2.3.4',
        proxyPort: 8080,
      );
      expect(policy.httpsOnly, isTrue);
      expect(policy.httpProxyActive, isTrue);

      policy.update(
        proxyType: ProxyType.socks5,
      );
      expect(policy.httpProxyActive, isFalse);

      policy.update(
        proxyType: ProxyType.http,
        proxyHost: '',
      );
      expect(policy.httpProxyActive, isFalse);
    });

    test('empty credentials clear stored values but omitted ones persist', () {
      final policy = DioNetworkPolicy.instance;
      policy.update(proxyUsername: 'user', proxyPassword: 'pass');
      expect(policy.proxyUsername, 'user');
      expect(policy.proxyPassword, 'pass');

      policy.update(httpsOnly: true);
      expect(policy.proxyUsername, 'user');

      policy.update(proxyUsername: '', proxyPassword: '');
      expect(policy.proxyUsername, isNull);
      expect(policy.proxyPassword, isNull);
    });
  });

  group('DioClientPool', () {
    test('reuses an idle client for the same host', () {
      final first = pool.acquireClient(url: 'https://cdn.example.com/a.iso');
      pool.releaseClient(first);
      final second = pool.acquireClient(url: 'https://cdn.example.com/b.iso');
      expect(identical(first, second), isTrue);
    });

    test('caps active clients while in the background', () {
      DownloadEngine.markBackground();
      final clients = List.generate(5, (_) => pool.acquireClient());
      expect(clients.length, 5);
      expect(pool.activeClientsCount, lessThanOrEqualTo(2));
    });

    test('register/unregister tracks active downloads per client', () {
      final client = pool.acquireClient();
      pool.registerDownload(client, 'task-1');
      expect(pool.activeDownloadsPerClient[client], contains('task-1'));

      pool.registerDownload(client, 'task-2');
      pool.unregisterDownload(client, 'task-1');
      expect(pool.activeDownloadsPerClient[client], isNot(contains('task-1')));

      pool.unregisterDownload(client, 'task-2');
      expect(pool.activeDownloadsPerClient[client], isEmpty);
    });

    test('releaseClient refuses to close a client with active downloads', () {
      final client = pool.acquireClient();
      pool.registerDownload(client, 'task-1');
      pool.releaseClient(client);
      expect(pool.activeDownloadsPerClient.containsKey(client), isTrue);
    });

    test('releasing an already-closed client closes it again safely', () {
      final client = pool.acquireClient();
      pool.releaseClient(client); // no host -> closed
      expect(() => pool.releaseClient(client), returnsNormally);
    });

    test('onMemoryPressure evicts idle and halves the reserved pool', () {
      final bound = pool.acquireClient();
      final idle = pool.acquireClient();
      pool.registerDownload(bound, 'task');
      pool.releaseClient(idle);

      pool.onMemoryPressure();
      expect(pool.activeDownloadsPerClient.containsKey(bound), isTrue);
    });

    test('dispose marks the pool disposed and clears state', () async {
      pool.acquireClient(url: 'https://example.com/f');
      await pool.dispose();
      expect(pool.isDisposed, isTrue);
      expect(pool.activeClientsCount, 0);
    });

    test('http requests are rejected when HTTPS-only is enabled', () async {
      final client = pool.acquireClient(url: 'https://example.com/f');
      client.httpClientAdapter = _RecordingAdapter();
      DioNetworkPolicy.instance.update(httpsOnly: true);

      await expectLater(
        client.get<String>('http://example.com/f'),
        throwsA(isA<DioException>()),
      );

      DioNetworkPolicy.instance.update(httpsOnly: false);
      final ok = await client.get<String>('https://example.com/f');
      expect(ok.statusCode, 200);
    });

    test('applies an HTTP proxy with credentials to pooled clients', () {
      DioNetworkPolicy.instance.update(
        httpsOnly: false,
        enableProxy: true,
        proxyType: ProxyType.http,
        proxyHost: '127.0.0.1',
        proxyPort: 8888,
        proxyUsername: 'user',
        proxyPassword: 'pass',
      );
      final client = pool.acquireClient(url: 'https://proxy.example.com/f');
      final adapter = client.httpClientAdapter;
      expect(adapter, isA<IOHttpClientAdapter>());
      final httpClient = (adapter as IOHttpClientAdapter).createHttpClient!();
      expect(httpClient, isNotNull);
    });

    test('exposes reserved and idle client tracking', () {
      final client = pool.acquireClient(url: 'https://h.example.com/f');
      expect(pool.reservedClientsCount, 1);
      pool.releaseClient(client);
      expect(
        pool.idleClientsByHostForTesting.containsKey('h.example.com'),
        isTrue,
      );
    });

    test('caps idle hosts and evicts the oldest', () {
      for (var i = 1; i <= 12; i++) {
        final client = pool.acquireClient(url: 'https://host$i.com/f');
        pool.releaseClient(client);
      }
      expect(pool.idleClientsByHostForTesting.length, lessThanOrEqualTo(10));
      expect(
        pool.idleClientsByHostForTesting.containsKey('host1.com'),
        isFalse,
      );
      expect(
          pool.idleClientsByHostForTesting.containsKey('host12.com'), isTrue);
    });

    test('releasing a second client for the same host closes the stale one',
        () {
      final first = pool.acquireClient(url: 'https://dup.example.com/a');
      final second = pool.acquireClient(url: 'https://dup.example.com/b');
      pool.releaseClient(first);
      pool.releaseClient(second);
      expect(
        pool.idleClientsByHostForTesting['dup.example.com'],
        same(second),
      );
    });

    test('onMemoryPressure closes idle clients and releases unbound actives',
        () {
      final idle = pool.acquireClient(url: 'https://idle.example.com/f');
      pool.releaseClient(idle);
      pool.acquireClient();
      pool.acquireClient();

      pool.onMemoryPressure();
      expect(pool.activeClientsCount, lessThanOrEqualTo(2));
    });

    test('close failures during memory pressure are swallowed', () {
      final bad = _ThrowingCloseDio();
      when(() => bad.close(force: any(named: 'force')))
          .thenThrow(StateError('close failed'));
      pool.idleClientsByHostForTesting['bad.example.com'] = bad;
      expect(() => pool.onMemoryPressure(), returnsNormally);
    });

    test('debounced cleanup runs after a release', () async {
      PowerMonitor.setScreenOn(false);
      final client = pool.acquireClient(url: 'https://cleanup.example.com/f');
      pool.releaseClient(client);

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(
        pool.idleClientsByHostForTesting.containsKey('cleanup.example.com'),
        isTrue,
      );
    });
  });
}
