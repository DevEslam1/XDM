import 'package:dmx/core/services/dio_client_pool.dart';
import 'package:dmx/core/services/service_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DioClientPool Memory Pressure & Capping Tests (L4)', () {
    late DioClientPool pool;

    setUp(() {
      pool = DioClientPool();
    });

    tearDown(() async {
      await pool.dispose();
    });

    test('caps pool at 6 max active clients when acquiring multiple clients',
        () {
      final clients = List.generate(12, (i) => pool.acquireClient());
      expect(clients.length, equals(12));
      expect(pool.activeClientsCount, lessThanOrEqualTo(6));
    });

    test('onMemoryPressure releases unbound clients and halves reserved pool',
        () {
      final clients = <dynamic>[];
      for (int i = 0; i < 6; i++) {
        clients.add(pool.acquireClient());
      }
      expect(pool.activeClientsCount, equals(6));

      // Bind 2 clients to active downloads
      pool.registerDownload(clients[0], 'task_1');
      pool.registerDownload(clients[1], 'task_2');

      // Broadcast memory pressure via ServiceRegistry
      ServiceRegistry.broadcastMemoryPressure();

      // Only the 2 bound clients should remain active
      expect(pool.activeClientsCount, equals(2));
      expect(pool.reservedClientsCount, lessThanOrEqualTo(4));
    });

    test('releaseClient guards against closing client with active downloads',
        () {
      final client = pool.acquireClient();
      for (int i = 0; i < 10; i++) {
        pool.registerDownload(client, 'task_$i');
      }
      expect(pool.activeDownloadsPerClient[client]?.length, equals(10));

      // Attempt to release client mid-flight -> should NOT force close
      pool.releaseClient(client);
      expect(pool.activeDownloadsPerClient.containsKey(client), isTrue);

      // Unregister all downloads
      for (int i = 0; i < 10; i++) {
        pool.unregisterDownload(client, 'task_$i');
      }
      expect(pool.activeDownloadsPerClient[client]?.isEmpty, isTrue);

      // Now releaseClient should cleanly remove the client
      pool.releaseClient(client);
      expect(pool.activeDownloadsPerClient.containsKey(client), isFalse);
    });
  });
}
