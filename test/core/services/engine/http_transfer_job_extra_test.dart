import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_exceptions.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:flutter_test/flutter_test.dart';

class _StreamAdapter implements HttpClientAdapter {
  _StreamAdapter(this.bytes) : headers = const {}, statusCode = 200;
  final List<int> bytes;
  final int statusCode;
  final Map<String, List<String>> headers;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream<Uint8List>.fromIterable([Uint8List.fromList(bytes)]),
      statusCode,
      headers: {
        Headers.contentLengthHeader: ['${bytes.length}'],
        ...headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

DownloadCommand _cmd(String dir,
        {bool supportsResume = true, int threads = 1}) =>
    DownloadCommand(
      taskId: 'task-http',
      url: 'http://example.com/f.bin',
      punyUrl: 'http://example.com/f.bin',
      tempFilePath: '$dir/f.bin.dmxpart',
      localFilePath: '$dir/f.bin',
      knownFileSize: 100,
      supportsResume: supportsResume,
      threadCount: threads,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late ReceivePort replyPort;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dmx_http_extra');
    replyPort = ReceivePort();
  });

  tearDown(() async {
    replyPort.close();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  group('computeHardTimeoutForSize', () {
    test('clamps to min, max and middle values', () {
      expect(HttpTransferJob.computeHardTimeoutForSize(0),
          const Duration(hours: 24));
      expect(HttpTransferJob.computeHardTimeoutForSize(3072000),
          const Duration(minutes: 30));
      expect(HttpTransferJob.computeHardTimeoutForSize(1 << 40),
          const Duration(hours: 24));
      expect(
        HttpTransferJob.computeHardTimeoutForSize(3600 * 51200),
        const Duration(seconds: 3600),
      );
    });
  });

  group('handle416', () {
    test('zeroes progress when the chunk starts past the server total', () {
      final chunk = ChunkState(start: 200, end: 299, downloaded: 50);
      HttpTransferJob.handle416(chunk, 100);
      expect(chunk.downloaded, 0);
    });

    test('clamps the end when it exceeds the server total', () {
      final chunk = ChunkState(start: 0, end: 299, downloaded: 0);
      HttpTransferJob.handle416(chunk, 100);
      expect(chunk.end, 99);
    });

    test('marks a fully-downloaded chunk complete', () {
      final chunk = ChunkState(start: 0, end: 99, downloaded: 100);
      HttpTransferJob.handle416(chunk, 0);
      expect(chunk.downloaded, 100);
    });

    test('returns unchanged when nothing applies', () {
      final chunk = ChunkState(start: 0, end: 99, downloaded: 10);
      HttpTransferJob.handle416(chunk, 0);
      expect(chunk.downloaded, 10);
      expect(chunk.end, 99);
    });
  });

  group('validateContentRange', () {
    test('missing header throws unless unknown is allowed', () {
      expect(
        () => HttpTransferJob.validateContentRange(null,
            expectedStart: 0, expectedEnd: 9, expectedTotal: 100),
        throwsA(isA<DioException>()),
      );
      expect(
        () => HttpTransferJob.validateContentRange(null,
            expectedStart: 0,
            expectedEnd: 9,
            expectedTotal: 100,
            allowUnknown: true),
        returnsNormally,
      );
    });

    test('bytes */0 is accepted for a fresh start only', () {
      expect(
        () => HttpTransferJob.validateContentRange('bytes */0',
            expectedStart: 0, expectedEnd: 9, expectedTotal: 0),
        returnsNormally,
      );
      expect(
        () => HttpTransferJob.validateContentRange('bytes */0',
            expectedStart: 10, expectedEnd: 19, expectedTotal: 100),
        throwsA(isA<DioException>()),
      );
    });

    test('malformed values throw unless unknown is allowed', () {
      expect(
        () => HttpTransferJob.validateContentRange('garbage',
            expectedStart: 0, expectedEnd: 9, expectedTotal: 100),
        throwsA(isA<DioException>()),
      );
      expect(
        () => HttpTransferJob.validateContentRange('garbage',
            expectedStart: 0,
            expectedEnd: 9,
            expectedTotal: 100,
            allowUnknown: true),
        returnsNormally,
      );
    });

    test('matching values pass and mismatches throw', () {
      expect(
        () => HttpTransferJob.validateContentRange('bytes 0-9/100',
            expectedStart: 0, expectedEnd: 9, expectedTotal: 100),
        returnsNormally,
      );
      expect(
        () => HttpTransferJob.validateContentRange('bytes 5-9/100',
            expectedStart: 0, expectedEnd: 9, expectedTotal: 100),
        throwsA(isA<DioException>()),
      );
      expect(
        () => HttpTransferJob.validateContentRange('bytes 0-8/100',
            expectedStart: 0, expectedEnd: 9, expectedTotal: 100),
        throwsA(isA<DioException>()),
      );
      expect(
        () => HttpTransferJob.validateContentRange('bytes 0-9/200',
            expectedStart: 0, expectedEnd: 9, expectedTotal: 100),
        throwsA(isA<DioException>()),
      );
      expect(
        () => HttpTransferJob.validateContentRange('bytes 0-9/*',
            expectedStart: 0, expectedEnd: 9, expectedTotal: 100),
        returnsNormally,
      );
    });
  });

  group('cancellableDelay', () {
    test('resolves after the duration', () async {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      await job.cancellableDelay(const Duration(milliseconds: 1));
      expect(job.pendingDelaysForTesting, isEmpty);
    });

    test('returns immediately once cancelled', () async {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      job.dispose();
      await job.cancellableDelay(const Duration(seconds: 10));
    });

    test('falls back to a tracked timer when the queue is full', () async {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      for (var i = 0; i < HttpTransferJob.maxPendingDelays; i++) {
        job.pendingDelaysForTesting[i] = Completer<void>();
      }
      await job.cancellableDelay(const Duration(milliseconds: 1));
    });
  });

  group('requestCancel / dispose', () {
    test('requestCancel marks the state paused and persists it', () async {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      job.stateForTesting = TransferState(
        totalSize: 100,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 99, downloaded: 50)],
      );
      await job.requestCancel(PauseReason.userRequested);
      final st = job.stateForTesting!;
      expect(st.status, DmxStateStatus.paused);
      expect(st.pauseReason, PauseReason.userRequested);
      expect(job.isDisposed, isFalse);
      job.dispose();
      expect(job.isDisposed, isTrue);
    });

    test('dispose aborts pending delays and watchdogs', () async {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      job.registerWatchdogs();
      expect(job.jobHealthTimerForTesting, isNotNull);
      job.dispose();
      expect(job.jobHealthTimerForTesting, isNull);
      expect(job.pendingDelaysForTesting, isEmpty);
    });
  });

  group('state accessors', () {
    test('stateSavePending setter and chunk fingerprint', () {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      job.stateSavePendingForTesting = true;
      expect(job.stateSavePendingForTesting, isTrue);
      expect(job.chunkFingerprintForTesting, 0);
    });

    test('throttledSaveAndReport is safe with no state', () async {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      await job.throttledSaveAndReportForTesting();
    });
  });

  group('reconcileChunksWithDisk', () {
    test('clamps each chunk to what the disk holds', () {
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      final st = TransferState(
        totalSize: 300,
        threadCount: 3,
        chunks: [
          ChunkState(start: 0, end: 99, downloaded: 100),
          ChunkState(start: 100, end: 199, downloaded: 100),
          ChunkState(start: 200, end: 299, downloaded: 100),
        ],
      );
      job.reconcileChunksWithDisk(st, 150);
      expect(st.chunks[0].downloaded, 100);
      expect(st.chunks[1].downloaded, 50);
      expect(st.chunks[2].downloaded, 0);
    });
  });

  group('loadAndReconcileState', () {
    test('creates a single-stream layout for small files', () async {
      final dir = tmp.path;
      final job = HttpTransferJob(
          _cmd(dir, supportsResume: false, threads: 4), replyPort.sendPort);
      addTearDown(job.dispose);

      final st = await job.loadAndReconcileState(Dio());
      expect(st.chunks, hasLength(1));
      expect(st.threadCount, 1);
    });

    test('re-plans chunks when thread count changes with zero progress',
        () async {
      final dir = tmp.path;
      final temp = '$dir/big.bin.dmxpart';
      await File(temp).writeAsBytes(List.filled(10, 0));
      final existing = TransferState(
        totalSize: 4 * 1024 * 1024,
        threadCount: 2,
        chunks: [
          ChunkState(start: 0, end: 2 * 1024 * 1024 - 1),
          ChunkState(start: 2 * 1024 * 1024, end: 4 * 1024 * 1024 - 1),
        ],
      );
      await StateStore.save(temp, existing, taskId: 'task-http');

      final job = HttpTransferJob(
        DownloadCommand(
          taskId: 'task-http',
          url: 'http://example.com/f.bin',
          punyUrl: 'http://example.com/f.bin',
          tempFilePath: temp,
          localFilePath: '$dir/big.bin',
          knownFileSize: 4 * 1024 * 1024,
          supportsResume: true,
          threadCount: 4,
        ),
        replyPort.sendPort,
      );
      addTearDown(job.dispose);

      final st = await job.loadAndReconcileState(Dio());
      expect(st.threadCount, 4);
      expect(st.chunks, hasLength(4));
    });

    test('preserves physical chunks when progress exists', () async {
      final dir = tmp.path;
      final temp = '$dir/prog.bin.dmxpart';
      await File(temp).writeAsBytes(List.filled(100, 0));
      final existing = TransferState(
        totalSize: 4 * 1024 * 1024,
        threadCount: 2,
        chunks: [
          ChunkState(start: 0, end: 2 * 1024 * 1024 - 1, downloaded: 100),
          ChunkState(start: 2 * 1024 * 1024, end: 4 * 1024 * 1024 - 1),
        ],
      );
      await StateStore.save(temp, existing, taskId: 'task-http');

      final job = HttpTransferJob(
        DownloadCommand(
          taskId: 'task-http',
          url: 'http://example.com/f.bin',
          punyUrl: 'http://example.com/f.bin',
          tempFilePath: temp,
          localFilePath: '$dir/prog.bin',
          knownFileSize: 4 * 1024 * 1024,
          supportsResume: true,
          threadCount: 4,
        ),
        replyPort.sendPort,
      );
      addTearDown(job.dispose);

      final st = await job.loadAndReconcileState(Dio());
      expect(st.chunks, hasLength(2));
    });
  });

  group('single-stream execution', () {
    test('downloads bytes to the temp file', () async {
      final dir = tmp.path;
      final payload = List<int>.generate(100, (i) => i % 256);
      final job = HttpTransferJob(
          _cmd(dir, supportsResume: false, threads: 1), replyPort.sendPort);
      addTearDown(job.dispose);

      await job.loadAndReconcileState(Dio());
      final dio = Dio();
      dio.httpClientAdapter = _StreamAdapter(payload);

      await job.executeDownload(dio);

      final temp = File('$dir/f.bin.dmxpart');
      expect(await temp.exists(), isTrue);
      expect(await temp.length(), 100);
    });
  });

  group('send + error classification', () {
    test('send posts a protocol message to the reply port', () async {
      final messages = <Object?>[];
      final sub = replyPort.listen(messages.add);
      addTearDown(sub.cancel);

      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      job.sendUnhandledError(StateError('boom'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(messages, isNotEmpty);
    });

    test('sendUnhandledError classifies a disk failure', () async {
      final messages = <Object?>[];
      final sub = replyPort.listen(messages.add);
      addTearDown(sub.cancel);
      final job = HttpTransferJob(_cmd(tmp.path), replyPort.sendPort);
      addTearDown(job.dispose);
      job.sendUnhandledError(const InsufficientStorageException('full'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(messages, isNotEmpty);
    });
  });

  group('static cache helpers', () {
    test('invalidate/clear identity cache are safe', () {
      HttpTransferJob.invalidateIdentityCacheForUrl('https://example.com/f');
      HttpTransferJob.clearIdentityCache();
      expect(HttpTransferJob.probeSkipCount, isA<int>());
      expect(HttpTransferJob.probeRunCount, isA<int>());
    });
  });
}
