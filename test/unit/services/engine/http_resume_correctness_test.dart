import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../test/helpers/scriptable_http_server.dart';

void main() {
  late Directory tempDir;
  late ScriptableHttpServer server;
  late Uint8List testPayload;
  late String expectedSha256;
  const fileSize = 512 * 1024; // 512 KB

  setUp(() async {
    HttpOverrides.global = null;
    tempDir =
        await Directory.systemTemp.createTemp('http_resume_correctness_test_');
    testPayload = Uint8List.fromList(
      List.generate(fileSize, (i) => (i * 43 + 17) % 256),
    );
    expectedSha256 = sha256.convert(testPayload).toString();

    server = ScriptableHttpServer();
    await server.start();
    server.setPayload(testPayload, etag: '"etag-v1"');
  });

  tearDown(() async {
    await server.stop();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Phase 1 — HTTP Resume Correctness & Corruption Hardening', () {
    test('1. HTTP 200 (Range Ignored) forces clean restart and emits telemetry',
        () async {
      final targetPath = '${tempDir.path}/range_ignored.bin';
      final tempPath = '${tempDir.path}/range_ignored.bin.tmp';
      final serverUrl = server.urlFor('/range_ignored.bin');

      // Server will ignore Range and send 200 OK full body
      server.setIgnoreRanges(true);

      // Pre-seed partial state
      final partState = TransferState(
        totalSize: fileSize,
        threadCount: 1,
        etag: '"etag-v1"',
        chunks: [
          ChunkState(start: 0, end: fileSize - 1, downloaded: 100000),
        ],
      );
      await StateStore.save(tempPath, partState, durable: true);
      await File(tempPath)
          .writeAsBytes(testPayload.sublist(0, 100000), flush: true);

      final cmd = DownloadCommand(
        taskId: 'range-ignored-1',
        url: serverUrl,
        punyUrl: serverUrl,
        localFilePath: targetPath,
        tempFilePath: tempPath,
        knownFileSize: fileSize,
        threadCount: 1,
        supportsResume: true,
      );

      final receivePort = ReceivePort();
      final messages = <dynamic>[];
      receivePort.listen((msg) => messages.add(msg));

      final job = HttpTransferJob(cmd, receivePort.sendPort);
      try {
        await job.run();
      } finally {
        receivePort.close();
      }

      final finalFile = File(targetPath);
      expect(await finalFile.exists(), isTrue);
      expect(await finalFile.length(), equals(fileSize));
      expect(sha256.convert(await finalFile.readAsBytes()).toString(),
          equals(expectedSha256));

      // Verify telemetry event emitted
      final hasTelemetry = messages.any((m) {
        if (m is! Map) return false;
        final map = Map<String, dynamic>.from(m);
        final data = map['data'] is Map
            ? Map<String, dynamic>.from(map['data'] as Map)
            : null;
        return map['type'] == 'telemetry' &&
            data?['event'] == 'resume_range_ignored';
      });
      expect(hasTelemetry, isTrue);
    });

    test('2. HTTP 416 Range Not Satisfiable reconciles correctly', () async {
      // Chunk at totalSize returns 416, should reconcile cleanly
      final chunk = ChunkState(start: 500, end: 999, downloaded: 500);
      final reconciled = HttpTransferJob.handle416(chunk, 1000);
      expect(reconciled.downloaded, equals(500));

      final pastEofChunk = ChunkState(start: 1200, end: 1500, downloaded: 100);
      final pastReconciled = HttpTransferJob.handle416(pastEofChunk, 1000);
      expect(pastReconciled.downloaded, equals(0));
    });

    test(
        '3. Simulated Kill -9 at 10%, 50%, 90% progresses with byte-identical checksum',
        () async {
      const checkpoints = [0.10, 0.50, 0.90];

      for (var i = 0; i < checkpoints.length; i++) {
        final ratio = checkpoints[i];
        final testTarget = '${tempDir.path}/kill_test_$i.bin';
        final testTemp = '${tempDir.path}/kill_test_$i.bin.tmp';
        final serverUrl = server.urlFor('/kill_test_$i.bin');

        final halfSize = (fileSize * ratio).round();
        final partA = halfSize ~/ 2;
        final partB = halfSize - partA;

        const mid = fileSize ~/ 2;
        final partState = TransferState(
          totalSize: fileSize,
          threadCount: 2,
          etag: '"etag-v1"',
          chunks: [
            ChunkState(start: 0, end: mid - 1, downloaded: partA),
            ChunkState(start: mid, end: fileSize - 1, downloaded: partB),
          ],
        );
        await StateStore.save(testTemp, partState, durable: true);

        final journal = DownloadJournal('$testTemp.journal');
        await journal.open();
        await journal.writeInit(2, fileSize);
        await journal.writeCheckpoint([partA, partB], fileSize);
        await journal.close();

        // Write partial bytes to disk at their respective chunk offsets
        final raf = await File(testTemp).open(mode: FileMode.write);
        await raf.setPosition(0);
        await raf.writeFrom(testPayload, 0, partA);
        await raf.setPosition(mid);
        await raf.writeFrom(testPayload, mid, mid + partB);
        await raf.flush();
        await raf.close();

        // Resume job (cold reboot)
        final cmd = DownloadCommand(
          taskId: 'kill-test-$i',
          url: serverUrl,
          punyUrl: serverUrl,
          localFilePath: testTarget,
          tempFilePath: testTemp,
          knownFileSize: fileSize,
          threadCount: 2,
          supportsResume: true,
        );

        final receivePort = ReceivePort();
        final job = HttpTransferJob(cmd, receivePort.sendPort);
        try {
          await job.run();
        } finally {
          receivePort.close();
        }

        final finalFile = File(testTarget);
        expect(await finalFile.exists(), isTrue);
        expect(await finalFile.length(), equals(fileSize));
        expect(sha256.convert(await finalFile.readAsBytes()).toString(),
            equals(expectedSha256));
      }
    });

    test('4. Redirect chain preserves Range headers across 302/307 redirects',
        () async {
      final targetPath = '${tempDir.path}/redirect_test.bin';
      final tempPath = '${tempDir.path}/redirect_test.bin.tmp';
      final startUrl = server.urlFor('/start_redirect');

      // Setup 302 -> 307 -> final payload redirect chain
      server.setRedirectChain(
          [HttpStatus.found, HttpStatus.temporaryRedirect], '/final_dest.bin');

      final cmd = DownloadCommand(
        taskId: 'redirect-matrix-1',
        url: startUrl,
        punyUrl: startUrl,
        localFilePath: targetPath,
        tempFilePath: tempPath,
        knownFileSize: fileSize,
        threadCount: 2,
        supportsResume: true,
      );

      final receivePort = ReceivePort();
      final job = HttpTransferJob(cmd, receivePort.sendPort);
      try {
        await job.run();
      } finally {
        receivePort.close();
      }

      final finalFile = File(targetPath);
      expect(await finalFile.exists(), isTrue);
      expect(await finalFile.length(), equals(fileSize));
      expect(sha256.convert(await finalFile.readAsBytes()).toString(),
          equals(expectedSha256));
    });
  });
}
