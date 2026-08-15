import 'dart:isolate';

import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HttpTransferJob Delay Capping (P0-6)', () {
    test('Stress test spawning 100 concurrent cancellable delays never exceeds 32 capacity', () async {
      final port = ReceivePort();
      const cmd = DownloadCommand(
        taskId: 'stress-delay-test',
        url: 'https://example.com/file',
        punyUrl: 'https://example.com/file',
        tempFilePath: 'stress.dmx',
        localFilePath: 'stress.bin',
        threadCount: 1,
        knownFileSize: 0,
        supportsResume: false,
      );

      final job = HttpTransferJob(cmd, port.sendPort);

      // Spawn 100 concurrent cancellable delays
      final futures = <Future<void>>[];
      for (var i = 0; i < 100; i++) {
        futures.add(job.cancellableDelay(const Duration(seconds: 10)));
      }

      // Assert lists never grow beyond 32 entries
      expect(job.pendingDelayCompletersForTesting.length, lessThanOrEqualTo(32));
      expect(job.pendingDelayTimersForTesting.length, lessThanOrEqualTo(32));
      expect(job.pendingDelayCompletersForTesting.length, equals(32));
      expect(job.pendingDelayTimersForTesting.length, equals(32));

      job.requestCancel();
      expect(job.pendingDelayCompletersForTesting, isEmpty);
      expect(job.pendingDelayTimersForTesting, isEmpty);

      port.close();
    });
  });
}
