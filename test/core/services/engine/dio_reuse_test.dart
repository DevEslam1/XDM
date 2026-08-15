import 'package:dmx/core/services/dio_client_pool.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Dio Client Reuse & Pooling (P0-10)', () {
    test('buildTransferDio reuses passed pooled Dio instance', () {
      final pool = DioClientPool();
      final client1 = pool.acquireClient(url: 'https://example.com/file1.zip');
      
      final clientReconfigured = buildTransferDio(
        url: 'https://example.com/file2.zip',
        customUserAgent: 'TestAgent/1.0',
        pooled: client1,
      );

      expect(identical(client1, clientReconfigured), isTrue);
      expect(clientReconfigured.options.headers['User-Agent'], equals('TestAgent/1.0'));

      pool.dispose();
    });

    test('DioClientPool reuses idle Dio instance across requests to same host', () {
      final pool = DioClientPool();

      final client1 = pool.acquireClient(url: 'https://cdn.example.org/downloads/a.iso');
      expect(client1, isNotNull);

      // Release client back to pool
      pool.releaseClient(client1);

      // Acquire next client for the same host
      final client2 = pool.acquireClient(url: 'https://cdn.example.org/downloads/b.iso');

      // Assert identical Dio instance is reused from pool
      expect(identical(client1, client2), isTrue);

      pool.dispose();
    });
  });
}
