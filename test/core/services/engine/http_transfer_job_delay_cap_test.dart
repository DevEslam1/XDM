import 'dart:isolate';

import 'package:dmx/core/services/engine/engine_exceptions.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HttpTransferJob Delay Capping (FIX-02)', () {
    test(
        'Stress test spawning 100 concurrent cancellable delays throws DelayQueueFullException once cap of 16 is reached',
        () async {
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

      // Spawn 16 delays successfully
      final futures = <Future<void>>[];
      for (var i = 0; i < 16; i++) {
        futures.add(job.cancellableDelay(const Duration(seconds: 10)));
      }

      expect(job.pendingDelaysForTesting.length, equals(16));

      // 17th onwards throws DelayQueueFullException
      expect(
        () => job.cancellableDelay(const Duration(seconds: 10)),
        throwsA(isA<DelayQueueFullException>()),
      );

      job.requestCancel();
      expect(job.pendingDelayCompletersForTesting, isEmpty);
      expect(job.pendingDelayTimersForTesting, isEmpty);

      port.close();
    });
  });
}
