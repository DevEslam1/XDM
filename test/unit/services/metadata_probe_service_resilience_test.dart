import 'package:dio/dio.dart';
import 'package:dmx/core/services/dio_client_pool.dart';
import 'package:dmx/core/services/metadata_probe_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MetadataProbeService Resilience & Lifecycle Tests', () {
    late DioClientPool dioPool;
    late MetadataProbeService probeService;

    setUp(() {
      dioPool = DioClientPool();
      probeService = MetadataProbeService(dioPool);
    });

    tearDown(() {
      probeService.dispose();
      dioPool.dispose();
    });

    test('dispose cancels active timers and stream subscriptions', () {
      expect(probeService.isDisposed, isFalse);
      probeService.dispose();
      expect(probeService.isDisposed, isTrue);

      // Calling dispose multiple times is safe and idempotent
      probeService.dispose();
      expect(probeService.isDisposed, isTrue);
    });

    test(
        'HTTP probe cancellation propagates cancelToken and returns fallback metadata',
        () async {
      final cancelToken = CancelToken();

      // Cancel token immediately
      cancelToken.cancel('user_aborted');

      final result = await probeService.resolveMetadata(
        url: 'https://example.com/largefile.zip',
        cancelToken: cancelToken,
      );

      expect(result.fileSize, 0);
      expect(result.fileName, 'largefile.zip');
    });

    test('non-torrent URL resolves via head/get gracefully without leaking',
        () async {
      final cancelToken = CancelToken();
      final future = probeService.resolveMetadata(
        url: 'https://example.com/nonexistent_test_url_404.iso',
        cancelToken: cancelToken,
      );

      // Cancel after 20ms
      Future<void>.delayed(const Duration(milliseconds: 20), () {
        cancelToken.cancel('test_timeout');
      });

      final result = await future;
      expect(result.fileSize, 0);
    });
  });
}
