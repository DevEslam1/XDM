import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_exceptions.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../test/helpers/scriptable_http_server.dart';

/// Regression tests for the HTTP-engine fix batch (H1-H8).
/// Each test name carries the bug id it pins.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ScriptableHttpServer server;
  late Uint8List payload;
  late String expectedSha256;
  const fileSize = 512 * 1024;

  setUp(() async {
    HttpOverrides.global = null;
    tempDir = await Directory.systemTemp.createTemp('http_fix_batch_test_');
    payload = Uint8List.fromList(
      List.generate(fileSize, (i) => (i * 43 + 17) % 256),
    );
    expectedSha256 = sha256.convert(payload).toString();

    server = ScriptableHttpServer();
    await server.start();
    server.setPayload(payload, etag: '"v1"');
  });

  tearDown(() async {
    HttpTransferJob.hardTimeoutForTesting = null;
    await server.stop();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  DownloadCommand buildCmd(String id, String tempPath, String targetPath,
          {bool resume = true,
          int threadCount = 1,
          bool integrity = true,
          bool expiresHint = false}) =>
      DownloadCommand(
        taskId: id,
        url: server.urlFor('/$id.bin'),
        punyUrl: server.urlFor('/$id.bin'),
        localFilePath: targetPath,
        tempFilePath: tempPath,
        knownFileSize: fileSize,
        threadCount: threadCount,
        supportsResume: resume,
        resumeIntegrityCheck: integrity,
        urlExpiresHint: expiresHint,
      );

  group('H1 — resume corruption cluster', () {
    test('F14: missing temp file with inflated state restarts from zero',
        () async {
      final tempPath = '${tempDir.path}/f14.bin.tmp';
      final state = TransferState(
        totalSize: fileSize,
        threadCount: 1,
        etag: '"v1"',
        chunks: [
          ChunkState(start: 0, end: fileSize - 1, downloaded: 100000),
        ],
      );

      final receivePort = ReceivePort();
      final job = HttpTransferJob(
          buildCmd('f14', tempPath, '${tempDir.path}/f14.bin'), receivePort.sendPort);
      job.stateForTesting = state;

      // Pre-fix: chunk.downloaded stayed 100000, FileMode.append misaligned
      // the 206 tail against a fresh empty file and the job failed (or,
      // across restart cycles, finalized shifted bytes).
      await job.executeDownload(Dio());

      final tempFile = File(tempPath);
      expect(await tempFile.exists(), isTrue);
      expect(await tempFile.length(), equals(fileSize));
      expect(sha256.convert(await tempFile.readAsBytes()).toString(),
          equals(expectedSha256));
      expect(state.chunks.first.downloaded, equals(fileSize));
      receivePort.close();
    });

    test('F15: single-stream 200-restart deletes the task-scoped state file',
        () async {
      final tempPath = '${tempDir.path}/f15.bin.tmp';
      await File(tempPath).writeAsBytes(payload.sublist(0, 100000), flush: true);
      await StateStore.save(
        tempPath,
        TransferState(
          totalSize: fileSize,
          threadCount: 1,
          etag: '"v1"',
          chunks: [
            ChunkState(start: 0, end: fileSize - 1, downloaded: 100000),
          ],
        ),
        durable: true,
        taskId: 'f15',
      );
      expect(
          await File(StateStore.pathFor(tempPath, taskId: 'f15')).exists(),
          isTrue);

      server.enqueue((request) => server.respondFull(request, status: 200));
      server.enqueue((request) => server.respondStatus(request, 404));

      final receivePort = ReceivePort();
      final job = HttpTransferJob(
          buildCmd('f15', tempPath, '${tempDir.path}/f15.bin',
              integrity: false),
          receivePort.sendPort);
      job.stateForTesting = TransferState(
        totalSize: fileSize,
        threadCount: 1,
        etag: '"v1"',
        chunks: [
          ChunkState(start: 0, end: fileSize - 1, downloaded: 100000),
        ],
      );

      // First request: ranged resume → 200 full (server ignored Range) →
      // clean restart. Second request: 404 → non-retryable failure, so the
      // state left on disk is observable.
      await expectLater(job.executeDownload(Dio()), throwsA(isA<DioException>()));

      final loaded = await StateStore.load(tempPath, taskId: 'f15');
      // Pre-fix the stale task-scoped snapshot (100000) survived the restart
      // via the journal's stale-write guard and resurrected on next resume.
      expect(loaded, isNotNull);
      expect(loaded!.chunks.first.downloaded, equals(0));
      receivePort.close();
    });

    test('F16: awaited reset wipes temp/state/journal before returning',
        () async {
      final tempPath = '${tempDir.path}/f16.bin.tmp';
      final state = TransferState(
        totalSize: fileSize,
        threadCount: 2,
        etag: '"v1"',
        chunks: [
          ChunkState(start: 0, end: fileSize ~/ 2 - 1, downloaded: 100000),
          ChunkState(start: fileSize ~/ 2, end: fileSize - 1, downloaded: 0),
        ],
      );
      await File(tempPath).writeAsBytes(payload.sublist(0, 100000), flush: true);
      await StateStore.save(tempPath, state, durable: true, taskId: 'f16');
      final journal = DownloadJournal('$tempPath.journal');
      await journal.open();
      await journal.writeInit(2, fileSize);
      await journal.close();

      final receivePort = ReceivePort();
      final job = HttpTransferJob(
          buildCmd('f16', tempPath, '${tempDir.path}/f16.bin', threadCount: 2),
          receivePort.sendPort);
      job.stateForTesting = state;

      await job.resetToSingleStreamForTesting();

      expect(await File(tempPath).exists(), isFalse);
      expect(
          await File(StateStore.pathFor(tempPath, taskId: 'f16')).exists(),
          isFalse);
      expect(await File('$tempPath.journal').exists(), isFalse);
      expect(state.chunks.length, equals(1));
      expect(state.downloadedBytes, equals(0));
      receivePort.close();
    });

    test(
        'F17: resume clamps chunks that claim bytes beyond the real disk length',
        () async {
      final tempPath = '${tempDir.path}/f17.bin.tmp';
      final mid = fileSize ~/ 2;
      // Disk only holds 100000 real bytes, but chunk 0 claims all 262144.
      // Pre-fix, openForResume pre-extended the file to totalSize so the
      // stale J4 pre-flight never fired: chunk 0 was already "complete",
      // the zero-filled hole [100000, 262144) passed the size check, and a
      // corrupt file was finalized.
      await File(tempPath).writeAsBytes(payload.sublist(0, 100000), flush: true);
      final state = TransferState(
        totalSize: fileSize,
        threadCount: 2,
        etag: '"v1"',
        chunks: [
          ChunkState(start: 0, end: mid - 1, downloaded: mid),
          ChunkState(start: mid, end: fileSize - 1, downloaded: 0),
        ],
      );

      final receivePort = ReceivePort();
      final job = HttpTransferJob(
          buildCmd('f17', tempPath, '${tempDir.path}/f17.bin', threadCount: 2),
          receivePort.sendPort);
      job.stateForTesting = state;
      await job.executeDownload(Dio());

      expect(state.migrationNote, contains('f17_disk_truth_clamp'));
      final tempFile = File(tempPath);
      expect(await tempFile.exists(), isTrue);
      expect(await tempFile.length(), equals(fileSize));
      expect(sha256.convert(await tempFile.readAsBytes()).toString(),
          equals(expectedSha256));
      receivePort.close();
    });
  });

  group('H2 — resumed-chunk digest correctness', () {
    test('F18: digest covers buffered bytes after mid-stream abort', () async {
      final tempPath = '${tempDir.path}/f18.bin.tmp';
      server.setDropConnectionAfterBytes(100000);

      final receivePort = ReceivePort();
      final messages = <dynamic>[];
      receivePort.listen(messages.add);
      final job = HttpTransferJob(
          buildCmd('f18', tempPath, '${tempDir.path}/f18.bin', threadCount: 2),
          receivePort.sendPort);
      try {
        await job.run();
      } finally {
        receivePort.close();
      }

      final finalFile = File('${tempDir.path}/f18.bin');
      expect(await finalFile.exists(), isTrue);
      expect(await finalFile.length(), equals(fileSize));
      expect(sha256.convert(await finalFile.readAsBytes()).toString(),
          equals(expectedSha256));
      expect(
          messages.any((m) =>
              m is Map && Map<String, dynamic>.from(m)['type'] == 'done'),
          isTrue);
    });
  });

  group('H3 — pause integrity', () {
    test('F7: reconcile keeps per-chunk disk truth without cumulative drift',
        () {
      final job = HttpTransferJob(
        buildCmd('f7', '${tempDir.path}/f7.tmp', '${tempDir.path}/f7.bin'),
        ReceivePort().sendPort,
      );

      // Contiguous chunks, disk frontier at 600: old math double-subtracted
      // chunk starts and dropped chunk 1's real 100 bytes.
      final st = TransferState(totalSize: 1000, threadCount: 2, chunks: [
        ChunkState(start: 0, end: 499, downloaded: 500),
        ChunkState(start: 500, end: 999, downloaded: 500),
      ]);
      job.reconcileChunksWithDisk(st, 600);
      expect(st.chunks[0].downloaded, equals(500));
      expect(st.chunks[1].downloaded, equals(100));

      // Indeterminate chunk (size < 0): old math clamped it to 0 outright.
      final st2 = TransferState(totalSize: 0, threadCount: 1, chunks: [
        ChunkState(start: 0, end: -1, downloaded: 800),
      ]);
      job.reconcileChunksWithDisk(st2, 600);
      expect(st2.chunks[0].downloaded, equals(600));

      // Chunk starting beyond the disk frontier keeps nothing.
      final st3 = TransferState(totalSize: 2000, threadCount: 2, chunks: [
        ChunkState(start: 0, end: 99, downloaded: 100),
        ChunkState(start: 1000, end: 1099, downloaded: 100),
      ]);
      job.reconcileChunksWithDisk(st3, 500);
      expect(st3.chunks[0].downloaded, equals(100));
      expect(st3.chunks[1].downloaded, equals(0));
    });

    test('F6: requestCancel persists a durability-clamped snapshot', () async {
      final tempPath = '${tempDir.path}/f6.bin.tmp';
      await StateStore.save(
        tempPath,
        TransferState(
          totalSize: 1000,
          threadCount: 1,
          chunks: [ChunkState(start: 0, end: 999, downloaded: 0)],
        ),
        durable: true,
        taskId: 'f6',
      );

      final receivePort = ReceivePort();
      final job = HttpTransferJob(
          buildCmd('f6', tempPath, '${tempDir.path}/f6.bin'), receivePort.sendPort);
      final dio = Dio();
      await job.loadAndReconcileState(dio); // sets durability baselines

      final writer = await PositionalFileWriter.open(tempPath,
          totalSize: 1000, threadCount: 1);
      job.activeWriterForTesting = writer;
      // 600 bytes buffered in the writer (not yet flushed)...
      await writer.write(0, 0, Uint8List.fromList(List.filled(600, 7)));
      // ...while the live chunk counter races ahead of the flushed bytes.
      job.stateForTesting!.chunks[0].downloaded = 1000;

      await job.requestCancel(PauseReason.user);

      final loaded = await StateStore.load(tempPath, taskId: 'f6');
      expect(loaded, isNotNull);
      expect(loaded!.status, equals(DmxStateStatus.paused));
      // Pre-fix the raw live counter (1000) was persisted — more than the
      // 600 bytes that ever reached the disk.
      expect(loaded.chunks.first.downloaded, equals(600));
      await writer.close();
      receivePort.close();
    });
  });

  group('H4 — hard timeout classification', () {
    test(
        'F10/F9: timeout sends exactly one error, persists PauseReason.timeout',
        () async {
      final tempPath = '${tempDir.path}/h4.bin.tmp';
      await StateStore.save(
        tempPath,
        TransferState(
          totalSize: fileSize,
          threadCount: 1,
          chunks: [ChunkState(start: 0, end: fileSize - 1, downloaded: 0)],
        ),
        durable: true,
        taskId: 'h4',
      );
      HttpTransferJob.hardTimeoutForTesting = const Duration(milliseconds: 300);
      server.enqueue((request) async {
        // Never respond — the hard timeout must break the deadlock.
        await Completer<void>().future;
      });

      final receivePort = ReceivePort();
      final messages = <dynamic>[];
      receivePort.listen(messages.add);
      final job = HttpTransferJob(
          buildCmd('h4', tempPath, '${tempDir.path}/h4.bin'), receivePort.sendPort);

      Object? caught;
      try {
        await job.run();
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<DioException>());

      // Simulate the workerEntry catch: the follow-on cancel must NOT be
      // re-emitted as a second error after the explicit timeout error.
      job.sendUnhandledError(caught!);

      final errorMessages = messages
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .where((m) => m['type'] == 'error')
          .toList();
      expect(errorMessages.length, equals(1));
      final errorData = Map<String, dynamic>.from(errorMessages.first['data']);
      expect(errorData['errorType'], equals('timeout'));

      final loaded = await StateStore.load(tempPath, taskId: 'h4');
      expect(loaded, isNotNull);
      expect(loaded!.status, equals(DmxStateStatus.paused));
      expect(loaded.pauseReason, equals(PauseReason.timeout));

      receivePort.close();
    });

    test('F3: hard timeout baseline is the documented 50 KB/s', () {
      final hour = HttpTransferJob.computeHardTimeoutForSize(
          3600 * 50 * 1024);
      expect(hour, equals(const Duration(hours: 1)));
      // Below the 30-minute floor it still clamps up.
      expect(
          HttpTransferJob.computeHardTimeoutForSize(60 * 50 * 1024),
          equals(const Duration(minutes: 30)));
    });
  });

  group('H5 — resume spot-check robustness', () {
    test('F12: 5xx during spot-check does not wipe resumed progress',
        () async {
      final tempPath = '${tempDir.path}/f12a.bin.tmp';
      await File(tempPath).writeAsBytes(payload.sublist(0, 100000), flush: true);
      server.enqueue((request) => server.respondStatus(request, 503));

      final receivePort = ReceivePort();
      final job = HttpTransferJob(
          buildCmd('f12a', tempPath, '${tempDir.path}/f12a.bin', threadCount: 2),
          receivePort.sendPort);
      final st = TransferState(
        totalSize: fileSize,
        threadCount: 2,
        etag: '"v1"',
        chunks: [
          ChunkState(start: 0, end: fileSize ~/ 2 - 1, downloaded: 100000),
          ChunkState(start: fileSize ~/ 2, end: fileSize - 1, downloaded: 0),
        ],
      );
      final writer = await PositionalFileWriter.openForResume(tempPath,
          threadCount: 2, totalSize: fileSize);
      try {
        await job.spotCheckResumedBytes(Dio(), st, writer);
      } finally {
        await writer.close();
      }
      expect(st.chunks[0].downloaded, equals(100000));
      receivePort.close();
    });

    test('F12: 200 (range ignored) during spot-check wipes the chunk',
        () async {
      final tempPath = '${tempDir.path}/f12b.bin.tmp';
      await File(tempPath).writeAsBytes(payload.sublist(0, 100000), flush: true);
      server.enqueue((request) => server.respondFull(request, status: 200));

      final receivePort = ReceivePort();
      final job = HttpTransferJob(
          buildCmd('f12b', tempPath, '${tempDir.path}/f12b.bin', threadCount: 2),
          receivePort.sendPort);
      final st = TransferState(
        totalSize: fileSize,
        threadCount: 2,
        etag: '"v1"',
        chunks: [
          ChunkState(start: 0, end: fileSize ~/ 2 - 1, downloaded: 100000),
          ChunkState(start: fileSize ~/ 2, end: fileSize - 1, downloaded: 0),
        ],
      );
      final writer = await PositionalFileWriter.openForResume(tempPath,
          threadCount: 2, totalSize: fileSize);
      try {
        await job.spotCheckResumedBytes(Dio(), st, writer);
      } finally {
        await writer.close();
      }
      expect(st.chunks[0].downloaded, equals(0));
      receivePort.close();
    });
  });

  group('H7 — expired-URL classification', () {
    test('F11: HTTP 410 classifies as expired URL (single-stream)', () async {
      final tempPath = '${tempDir.path}/f11a.bin.tmp';
      server.enqueue((request) => server.respondStatus(request, 410));

      final receivePort = ReceivePort();
      final messages = <dynamic>[];
      receivePort.listen(messages.add);
      final job = HttpTransferJob(
          buildCmd('f11a', tempPath, '${tempDir.path}/f11a.bin',
              expiresHint: true),
          receivePort.sendPort);
      job.stateForTesting = TransferState(
        totalSize: fileSize,
        threadCount: 1,
        etag: '"v1"',
        chunks: [ChunkState(start: 0, end: fileSize - 1, downloaded: 0)],
      );

      // Pre-fix, 410 fell through to the generic non-retryable failure
      // instead of the link-refresh flow.
      await expectLater(
          job.executeDownload(Dio()), throwsA(isA<UrlExpiredException>()));

      final progressMaps = messages
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .where((m) => m['type'] == 'progress')
          .map((m) => Map<String, dynamic>.from(m['data'] as Map))
          .toList();
      expect(
          progressMaps.any((p) => p['cycleState'] == CycleState.updatingLinks.name),
          isTrue);
      receivePort.close();
    });

    test('F11: HTTP 410 classifies as expired URL (chunk path)', () async {
      final tempPath = '${tempDir.path}/f11b.bin.tmp';
      // 512 KB >= minSizeForMultithread with threadCount 2 → chunked path.
      server.enqueue((request) => server.respondStatus(request, 410));

      final receivePort = ReceivePort();
      final job = HttpTransferJob(
          buildCmd('f11b', tempPath, '${tempDir.path}/f11b.bin',
              threadCount: 2, expiresHint: true),
          receivePort.sendPort);
      job.stateForTesting = TransferState(
        totalSize: fileSize,
        threadCount: 2,
        etag: '"v1"',
        chunks: [
          ChunkState(start: 0, end: fileSize ~/ 2 - 1, downloaded: 0),
          ChunkState(start: fileSize ~/ 2, end: fileSize - 1, downloaded: 0),
        ],
      );

      await expectLater(
          job.executeDownload(Dio()), throwsA(isA<UrlExpiredException>()));
      receivePort.close();
    });

    test('F11: 410 without expiry signals is NOT an expired URL', () async {
      final tempPath = '${tempDir.path}/f11c.bin.tmp';
      server.enqueue((request) => server.respondStatus(request, 410));

      final receivePort = ReceivePort();
      final job = HttpTransferJob(
          buildCmd('f11c', tempPath, '${tempDir.path}/f11c.bin'),
          receivePort.sendPort);
      job.stateForTesting = TransferState(
        totalSize: fileSize,
        threadCount: 1,
        etag: '"v1"',
        chunks: [ChunkState(start: 0, end: fileSize - 1, downloaded: 0)],
      );

      // No urlExpiresHint / signed-URL markers → stays a generic failure.
      await expectLater(
          job.executeDownload(Dio()), throwsA(isA<DioException>()));
      receivePort.close();
    });
  });

  group('H8 — small correctness', () {
    test('F4: stalledThreshold is per-job, not clobbered across jobs', () {
      final portA = ReceivePort();
      final portB = ReceivePort();
      final jobA = HttpTransferJob(
        DownloadCommand(
          taskId: 'f4-a',
          url: server.urlFor('/f4a.bin'),
          punyUrl: server.urlFor('/f4a.bin'),
          localFilePath: '${tempDir.path}/f4a.bin',
          tempFilePath: '${tempDir.path}/f4a.tmp',
          knownFileSize: fileSize,
          threadCount: 1,
          supportsResume: true,
          stalledTimeoutMinutes: 5,
        ),
        portA.sendPort,
      );
      final jobB = HttpTransferJob(
        DownloadCommand(
          taskId: 'f4-b',
          url: server.urlFor('/f4b.bin'),
          punyUrl: server.urlFor('/f4b.bin'),
          localFilePath: '${tempDir.path}/f4b.bin',
          tempFilePath: '${tempDir.path}/f4b.tmp',
          knownFileSize: fileSize,
          threadCount: 1,
          supportsResume: true,
          stalledTimeoutMinutes: 9,
        ),
        portB.sendPort,
      );

      jobA.registerWatchdogs();
      jobB.registerWatchdogs();
      expect(jobA.stalledThreshold, equals(const Duration(minutes: 5)));
      expect(jobB.stalledThreshold, equals(const Duration(minutes: 9)));
      jobA.cancelWatchdogs();
      jobB.cancelWatchdogs();
      portA.close();
      portB.close();
    });

    test('F26: capped fallback delay cleans up its timer and completer',
        () async {
      final receivePort = ReceivePort();
      final job = HttpTransferJob(
          buildCmd('f26', '${tempDir.path}/f26.tmp', '${tempDir.path}/f26.bin'),
          receivePort.sendPort);

      final futures = <Future<void>>[];
      for (var i = 0; i < 16; i++) {
        futures.add(job.cancellableDelay(const Duration(seconds: 30)));
      }
      expect(job.pendingDelaysForTesting.length, equals(16));

      // 17th delay goes through the fallback path and must complete —
      // leaving no leaked listener, timer, or completer behind.
      await job.cancellableDelay(const Duration(milliseconds: 10));
      expect(job.pendingDelaysForTesting.containsKey(16), isFalse);

      job.requestCancel();
      await Future.wait(futures).timeout(const Duration(seconds: 5));
      receivePort.close();
    });
  });
}
