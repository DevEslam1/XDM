import 'dart:isolate';
import 'package:dmx/core/services/engine/engine_exceptions.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HttpTransferJob Hardening (Sprint 1)', () {
    test('cancellableDelay throws DelayQueueFullException when queue capacity is reached', () async {
      final receivePort = ReceivePort();
      const cmd = DownloadCommand(
        taskId: 'test-delay-cap',
        url: 'https://example.com/test.bin',
        punyUrl: 'https://example.com/test.bin',
        tempFilePath: 'test.tmp',
        localFilePath: 'test.bin',
        threadCount: 1,
        knownFileSize: 1000,
        supportsResume: true,
      );

      final job = HttpTransferJob(cmd, receivePort.sendPort);

      // Enqueue 16 delays
      final futures = <Future<void>>[];
      for (var i = 0; i < 16; i++) {
        futures.add(job.cancellableDelay(const Duration(seconds: 10)));
      }
      expect(job.pendingDelaysForTesting.length, equals(16));

      // 17th delay must throw DelayQueueFullException
      expect(
        () => job.cancellableDelay(const Duration(seconds: 10)),
        throwsA(isA<DelayQueueFullException>()),
      );

      job.requestCancel();
      receivePort.close();
    });

    test('registerWatchdogs sets single _jobHealthTimer and cancelWatchdogs clears it', () {
      final receivePort = ReceivePort();
      const cmd = DownloadCommand(
        taskId: 'test-watchdogs',
        url: 'https://example.com/test.bin',
        punyUrl: 'https://example.com/test.bin',
        tempFilePath: 'test.tmp',
        localFilePath: 'test.bin',
        threadCount: 1,
        knownFileSize: 1000,
        supportsResume: true,
      );

      final job = HttpTransferJob(cmd, receivePort.sendPort);
      job.registerWatchdogs();
      expect(job.jobHealthTimerForTesting, isNotNull);
      expect(job.jobHealthTimerForTesting!.isActive, isTrue);

      job.cancelWatchdogs();
      expect(job.jobHealthTimerForTesting, isNull);

      job.requestCancel();
      receivePort.close();
    });
  });
}
