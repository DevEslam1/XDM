import 'dart:isolate';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HttpTransferJob CancellableDelay Queue Overflow Fallback (P0-05)', () {
    test('coalesces to direct Future.delayed fallback instead of throwing exception', () async {
      final port = ReceivePort();
      const cmd = DownloadCommand(
        taskId: 'overflow-test',
        url: 'https://example.com/file',
        punyUrl: 'https://example.com/file',
        tempFilePath: 'overflow.tmp',
        localFilePath: 'overflow.bin',
        threadCount: 1,
        knownFileSize: 1000,
        supportsResume: true,
      );

      final job = HttpTransferJob(cmd, port.sendPort);

      // Fill exactly 16 cancellable delays
      final initialDelays = <Future<void>>[];
      for (int i = 0; i < 16; i++) {
        initialDelays.add(job.cancellableDelay(const Duration(seconds: 10)));
      }

      expect(job.pendingDelaysForTesting.length, equals(16));

      // Attempt 17th delay - must not throw DelayQueueFullException, but complete safely via fallback
      final fallbackFuture = job.cancellableDelay(const Duration(milliseconds: 20));
      await expectLater(fallbackFuture, completes);

      // Pending tracked delays remain at 16 (fallback is non-cancellable direct Future.delayed)
      expect(job.pendingDelaysForTesting.length, equals(16));

      job.requestCancel();
      expect(job.pendingDelayCompletersForTesting, isEmpty);
      expect(job.pendingDelayTimersForTesting, isEmpty);

      port.close();
    });
  });
}
