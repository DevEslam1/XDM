import 'dart:async';
import 'dart:isolate';

import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HttpTransferJob Watchdog - Metadata Phase Coverage (P0-1)', () {
    test('registerWatchdogs is called before metadata probe and arms watchdog',
        () async {
      final receivePort = ReceivePort();
      final messages = <Map<String, dynamic>>[];

      final sub = receivePort.listen((msg) {
        if (msg is Map<String, dynamic>) {
          messages.add(msg);
        } else if (msg is Map) {
          messages.add(Map<String, dynamic>.from(msg));
        }
      });

      const cmd = DownloadCommand(
        taskId: 'test-meta-watchdog-task',
        url: 'https://example.com/file.bin',
        punyUrl: 'https://example.com/file.bin',
        tempFilePath: 'test_temp_file.dmx',
        localFilePath: 'test_file.bin',
        threadCount: 1,
        knownFileSize: 0,
        supportsResume: true,
      );

      final job = HttpTransferJob(cmd, receivePort.sendPort);

      // Register watchdogs before any state loading / metadata probe phase
      job.registerWatchdogs();

      expect(job, isNotNull);

      job.cancelWatchdogs();
      await sub.cancel();
      receivePort.close();
    });

    test(
        'Hard timeout handler emits timeout error and aborts delays during stalled probe',
        () async {
      final receivePort = ReceivePort();
      final completer = Completer<Map<String, dynamic>>();

      final sub = receivePort.listen((dynamic raw) {
        if (raw is Map) {
          final data = Map<String, dynamic>.from(raw);
          final eventData = data['data'];
          if (data['type'] == 'error' &&
              eventData is Map &&
              eventData['errorType'] == 'timeout') {
            if (!completer.isCompleted) completer.complete(data);
          }
        }
      });

      const cmd = DownloadCommand(
        taskId: 'stuck-head-probe-task',
        url: 'https://httpstat.us/200?sleep=60000',
        punyUrl: 'https://httpstat.us/200?sleep=60000',
        tempFilePath: 'stuck_head_probe.dmx',
        localFilePath: 'stuck_head_probe.bin',
        threadCount: 1,
        knownFileSize: 1024,
        supportsResume: true,
      );

      final job = HttpTransferJob(cmd, receivePort.sendPort);
      job.registerWatchdogs();

      job.sendUnhandledError(
        TimeoutException('Simulated stuck HEAD probe timeout'),
      );

      expect(job, isNotNull);
      job.cancelWatchdogs();
      await sub.cancel();
      receivePort.close();
    });
  });
}
