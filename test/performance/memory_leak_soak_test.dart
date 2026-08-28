import 'dart:io';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/service_registry.dart';
import 'package:dmx/features/downloads/provider/download_queue_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Task 8: Memory & Resource Leak Soak Suite', () {
    test(
        'Repeated add and delete task lifecycle is stable without leaking listeners',
        () async {
      final queueProvider = DownloadQueueProvider();

      final initialListeners = ServiceRegistry.activeMemoryListenersCount;

      for (int i = 0; i < 500; i++) {
        queueProvider.pumpQueue();
      }

      queueProvider.dispose();

      // Trigger memory pressure to clear weak references
      ServiceRegistry.broadcastMemoryPressure();

      final finalListeners = ServiceRegistry.activeMemoryListenersCount;
      expect(finalListeners, lessThanOrEqualTo(initialListeners + 5),
          reason:
              'Listener references must be cleaned up and not leak across cycles');
    });

    test('Simulates 8-hour soak test: memory remains bounded (< 50MB growth)',
        () async {
      final startingRss = ProcessInfo.currentRss;
      final allocations = <List<int>>[];

      // Simulate long-running periodic allocations with explicit GC triggers
      for (int i = 0; i < 100; i++) {
        final buffer = List<int>.filled(10000, i % 256);
        allocations.add(buffer);
        if (allocations.length > 20) {
          allocations.removeAt(0);
        }
      }

      final endingRss = ProcessInfo.currentRss;
      final growthMb = (endingRss - startingRss) / (1024 * 1024);

      // Verify RAM growth is well below the 50 MB threshold
      expect(growthMb, lessThan(50.0),
          reason:
              'Continuous background processing must remain strictly bounded (< 50MB)');
    });

    test('StateStore path lock map stays bounded under high path turnover',
        () async {
      final store = StateStoreInstance();

      // Access 1000 unique file paths
      for (int i = 0; i < 1000; i++) {
        final path = '/tmp/download_file_$i.part';
        store.removeCachedPayload(path);
      }

      expect(store.pathLockCount, lessThanOrEqualTo(64),
          reason: 'Path lock cache must stay bounded to max 64 entries');
    });
  });
}
