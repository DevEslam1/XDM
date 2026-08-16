import 'dart:isolate';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HttpTransferJob Hardening (Sprint 1)', () {
    test('cancellableDelay falls back to direct delay when queue capacity (16) is reached', () async {
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

      // 17th delay must coalesce to direct Future.delayed without throwing
      expect(
        job.cancellableDelay(const Duration(milliseconds: 10)),
        completes,
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

    test('throttledSaveAndReport skips work while a state save is pending', () async {
      final receivePort = ReceivePort();
      const cmd = DownloadCommand(
        taskId: 'test-throttle-skip',
        url: 'https://example.com/test.bin',
        punyUrl: 'https://example.com/test.bin',
        tempFilePath: 'test.tmp',
        localFilePath: 'test.bin',
        threadCount: 1,
        knownFileSize: 1000,
        supportsResume: true,
      );

      final job = HttpTransferJob(cmd, receivePort.sendPort);

      // With a save pending, the call must return immediately without
      // touching _state (which is null here) — proving the skip guard runs
      // before any state access.
      job.stateSavePendingForTesting = true;
      await job.throttledSaveAndReportForTesting();
      expect(job.stateSavePendingForTesting, isTrue);

      job.requestCancel();
      receivePort.close();
    });
  });
}
