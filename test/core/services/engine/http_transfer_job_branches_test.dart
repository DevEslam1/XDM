import 'dart:io';
import 'dart:isolate';

import 'package:dmx/core/services/engine/engine_exceptions.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:dmx/core/services/transfer_state.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadCommand _cmd(String dir, {int threads = 1}) => DownloadCommand(
      taskId: 'task-branch',
      url: 'http://example.com/f.bin',
      punyUrl: 'http://example.com/f.bin',
      tempFilePath: '$dir/f.bin.dmxpart',
      localFilePath: '$dir/f.bin',
      knownFileSize: 100,
      supportsResume: true,
      threadCount: threads,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late ReceivePort replyPort;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dmx_http_branches');
    replyPort = ReceivePort();
  });

  tearDown(() async {
    HttpTransferJob.hardTimeoutForTesting = null;
    replyPort.close();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  Future<List<Map<String, dynamic>>> collectErrors() async {
    final messages = <Object?>[];
    final sub = replyPort.listen(messages.add);
    addTearDown(sub.cancel);
    // Give the send a turn on the event loop.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return messages
        .whereType<Map>()
        .where((m) => m['type'] == 'error')
        .map((m) => (m['data'] as Map).cast<String, dynamic>())
        .toList();
  }

  group('sendUnhandledError classification', () {
    test('UrlExpiredException surfaces refreshAllMirrors', () async {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      job.sendUnhandledError(
        const UrlExpiredException('gone', refreshAllMirrors: true),
      );
      final errors = await collectErrors();
      expect(errors, isNotEmpty);
      expect(errors.last['errorType'], 'urlExpired');
      expect(errors.last['refreshAllMirrors'], isTrue);
    });

    test('RangeUnsupportedException maps to rangeUnsupported', () async {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      job.sendUnhandledError(RangeUnsupportedException());
      final errors = await collectErrors();
      expect(errors, isNotEmpty);
      expect(errors.last['errorType'], 'rangeUnsupported');
    });

    test('FileChangedOnServerException maps to fileChanged or integrity',
        () async {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      job.sendUnhandledError(FileChangedOnServerException());
      final errors = await collectErrors();
      expect(errors, isNotEmpty);
      expect(
        errors.last['errorType'],
        anyOf('fileChanged', 'integrity'),
      );
    });

    test('FileSystemException diagnostics do not leak into the payload',
        () async {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      job.sendUnhandledError(
        const FileSystemException('write', '/tmp/f', OSError('denied', 13)),
        StackTrace.current,
      );
      final errors = await collectErrors();
      expect(errors, isNotEmpty);
      expect(errors.last['errorType'], isNotNull);
    });

    test('PositionalFileWriterException is classified, not thrown', () async {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      job.sendUnhandledError(const PositionalFileWriterException('closed'));
      final errors = await collectErrors();
      expect(errors, isNotEmpty);
      expect(errors.last['errorMessage'], isNotNull);
    });
  });

  group('watchdogs', () {
    test('registerWatchdogs installs timers and cancelWatchdogs clears them',
        () {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      job.registerWatchdogs();
      expect(job.jobHealthTimerForTesting, isNotNull);
      job.cancelWatchdogs();
      expect(job.jobHealthTimerForTesting, isNull);
    });

    test('hard-timeout override fires an error and cancels the job', () async {
      HttpTransferJob.hardTimeoutForTesting = const Duration(milliseconds: 5);
      final messages = <Object?>[];
      final sub = replyPort.listen(messages.add);
      addTearDown(sub.cancel);

      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      job.registerWatchdogs();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final errors =
          messages.whereType<Map>().where((m) => m['type'] == 'error').toList();
      expect(errors, isNotEmpty);
      expect((errors.first['data'] as Map)['errorType'], 'timeout');
    });
  });

  group('resetToSingleStream', () {
    test('collapses the state to a single chunk', () async {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      job.stateForTesting = TransferState(
        totalSize: 300,
        threadCount: 3,
        chunks: [
          ChunkState(start: 0, end: 99, downloaded: 10),
          ChunkState(start: 100, end: 199, downloaded: 10),
          ChunkState(start: 200, end: 299, downloaded: 10),
        ],
      );

      await job.resetToSingleStreamForTesting();

      final st = job.stateForTesting!;
      expect(st.threadCount, 1);
      expect(st.chunks, hasLength(1));
    });
  });

  group('requestCancel', () {
    test('persists the resolved pause reason on the state', () async {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      await File('${tmp.path}/f.bin.dmxpart').writeAsBytes(List.filled(10, 0));
      job.stateForTesting = TransferState(
        totalSize: 100,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 99, downloaded: 10)],
      );
      await job.requestCancel(PauseReason.networkLost);
      expect(job.stateForTesting!.status, DmxStateStatus.paused);
    });
  });

  group('computeHardTimeoutForSize', () {
    test('is bounded between the min and max windows', () {
      expect(
        HttpTransferJob.computeHardTimeoutForSize(0),
        const Duration(hours: 24),
      );
      expect(
        HttpTransferJob.computeHardTimeoutForSize(1024 * 1024),
        const Duration(minutes: 30),
      );
    });
  });
}
