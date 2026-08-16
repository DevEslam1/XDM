import 'package:dmx/core/services/dio_client_pool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DioClientPool Hardening (Sprint 2)', () {
    test('Cap idle clients per host at 10 and evict oldest LRU on releaseClient', () async {
      final pool = DioClientPool(enableCleanupTimer: false);

      // Acquire and release for 12 different hosts
      for (int i = 1; i <= 12; i++) {
        final client = pool.acquireClient(url: 'https://host$i.com/file');
        pool.releaseClient(client);
      }

      // Max 10 idle hosts cached
      expect(pool.idleClientsByHostForTesting.length, lessThanOrEqualTo(10));
      expect(pool.idleClientsByHostForTesting.containsKey('host1.com'), isFalse);
      expect(pool.idleClientsByHostForTesting.containsKey('host12.com'), isTrue);

      await pool.dispose();
    });
  });
}
