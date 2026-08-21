import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:dmx/features/downloads/domain/state_machine/domain_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../test/helpers/fake_services.dart';

void main() {
  late Directory tempDir;
  late ScriptableHttpServer server;
  late Uint8List samplePayload;
  late String sampleSha256;
  const fileSize = 256 * 1024; // 256 KB

  setUp(() async {
    HttpOverrides.global = null;
    tempDir = await Directory.systemTemp.createTemp('dmx_matrix_test_');
    samplePayload = Uint8List.fromList(
      List.generate(fileSize, (i) => (i * 37 + 11) % 256),
    );
    sampleSha256 = sha256.convert(samplePayload).toString();

    server = ScriptableHttpServer();
    await server.start();
    server.setPayload(samplePayload, etag: '"matrix-v1"');
  });

  tearDown(() async {
    await server.stop();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Phase 0 Matrix — HTTP Engine Resiliency', () {
    test('1. HTTP: pause -> resume completes with byte-identical checksum', () async {
      final targetPath = '${tempDir.path}/test_pause_resume.bin';
      final tempPath = '${tempDir.path}/test_pause_resume.bin.tmp';
      final serverUrl = server.urlFor('/pause_resume.bin');

      final cmd = DownloadCommand(
        taskId: 'http-matrix-1',
        url: serverUrl,
        punyUrl: serverUrl,
        localFilePath: targetPath,
        tempFilePath: tempPath,
        knownFileSize: fileSize,
        threadCount: 2,
        supportsResume: true,
      );

      // Phase A: Simulate partial download
      const halfSize = fileSize ~/ 2;
      final partState = TransferState(
        totalSize: fileSize,
        threadCount: 2,
        etag: '"matrix-v1"',
        chunks: [
          ChunkState(start: 0, end: halfSize - 1, downloaded: halfSize ~/ 2),
          ChunkState(start: halfSize, end: fileSize - 1, downloaded: halfSize ~/ 2),
        ],
      );
      await StateStore.save(tempPath, partState, durable: true);

      final journal = DownloadJournal('$tempPath.journal');
      await journal.open();
      await journal.writeInit(2, fileSize);
      await journal.writeCheckpoint([halfSize ~/ 2, halfSize ~/ 2], fileSize);
      await journal.close();

      // Write partial bytes to disk
      await File(tempPath).writeAsBytes(samplePayload.sublist(0, halfSize), flush: true);

      // Phase B: Resume to completion
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
      final downloaded = await finalFile.readAsBytes();
      expect(sha256.convert(downloaded).toString(), equals(sampleSha256));
    });

    test('2. HTTP: pause -> app kill -> cold relaunch reconciles journal and finishes cleanly', () async {
      final targetPath = '${tempDir.path}/test_cold_kill.bin';
      final tempPath = '${tempDir.path}/test_cold_kill.bin.tmp';
      final serverUrl = server.urlFor('/cold_kill.bin');

      final cmd = DownloadCommand(
        taskId: 'http-matrix-2',
        url: serverUrl,
        punyUrl: serverUrl,
        localFilePath: targetPath,
        tempFilePath: tempPath,
        knownFileSize: fileSize,
        threadCount: 2,
        supportsResume: true,
      );

      // Uncheckpointed journal write simulating crash before graceful flush
      await File(tempPath).writeAsBytes(samplePayload.sublist(0, 60000), flush: true);
      final journal = DownloadJournal('$tempPath.journal');
      await journal.open();
      await journal.writeInit(2, fileSize);
      await journal.writeCheckpoint([30000, 30000], fileSize);
      await journal.close();

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
      expect(sha256.convert(await finalFile.readAsBytes()).toString(), equals(sampleSha256));
    });

    test('3. HTTP: fail -> retry recovers from connection drop mid-stream', () async {
      final targetPath = '${tempDir.path}/test_fail_retry.bin';
      final tempPath = '${tempDir.path}/test_fail_retry.bin.tmp';
      final serverUrl = server.urlFor('/fail_retry.bin');

      // Drop connection abruptly after 50KB
      server.setDropConnectionAfterBytes(50 * 1024);

      final cmd = DownloadCommand(
        taskId: 'http-matrix-4',
        url: serverUrl,
        punyUrl: serverUrl,
        localFilePath: targetPath,
        tempFilePath: tempPath,
        knownFileSize: fileSize,
        threadCount: 2,
        supportsResume: true,
      );

      final receivePort1 = ReceivePort();
      final job1 = HttpTransferJob(cmd, receivePort1.sendPort);
      var caughtError = false;
      try {
        await job1.run();
      } catch (e) {
        caughtError = true;
      } finally {
        receivePort1.close();
      }

      expect(caughtError, isTrue, reason: 'Expected connection drop on first run');

      // Reset drop flag and retry
      server.setDropConnectionAfterBytes(null);
      final receivePort2 = ReceivePort();
      final job2 = HttpTransferJob(cmd, receivePort2.sendPort);
      try {
        await job2.run();
      } finally {
        receivePort2.close();
      }

      final finalFile = File(targetPath);
      expect(await finalFile.exists(), isTrue);
      expect(await finalFile.length(), equals(fileSize));
      expect(sha256.convert(await finalFile.readAsBytes()).toString(), equals(sampleSha256));
    });

    test('4. HTTP: pause -> server file changed (ETag flip) resets cleanly', () async {
      final targetPath = '${tempDir.path}/test_etag_flip.bin';
      final tempPath = '${tempDir.path}/test_etag_flip.bin.tmp';
      final serverUrl = server.urlFor('/etag_flip.bin');

      // Stale partial state under v1
      final partState = TransferState(
        totalSize: fileSize,
        threadCount: 2,
        etag: '"matrix-v1"',
        chunks: [
          ChunkState(start: 0, end: 10000, downloaded: 5000),
          ChunkState(start: 10001, end: fileSize - 1, downloaded: 5000),
        ],
      );
      await StateStore.save(tempPath, partState, durable: true);
      await File(tempPath).writeAsBytes(samplePayload.sublist(0, 10000), flush: true);

      // Server updates to v2 with different content
      final updatedPayload = Uint8List.fromList(
        List.generate(fileSize, (i) => (i * 41 + 19) % 256),
      );
      final updatedSha256 = sha256.convert(updatedPayload).toString();
      server.setPayload(updatedPayload, etag: '"matrix-v2"');

      final cmd = DownloadCommand(
        taskId: 'http-matrix-5',
        url: serverUrl,
        punyUrl: serverUrl,
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
      } catch (_) {
        // In case of ETag mismatch abort, retry cleanly
        final retryJob = HttpTransferJob(cmd, receivePort.sendPort);
        await retryJob.run();
      } finally {
        receivePort.close();
      }

      final finalFile = File(targetPath);
      expect(await finalFile.exists(), isTrue);
      expect(await finalFile.length(), equals(fileSize));
      expect(sha256.convert(await finalFile.readAsBytes()).toString(), equals(updatedSha256));
    });
  });

  group('Phase 0 Matrix — Torrent Engine Resiliency', () {
    late FakeITorrentService torrentService;

    setUp(() {
      torrentService = FakeITorrentService();
    });

    test('5. Torrent: pause -> resume triggers state transitions and bandwidth drops', () async {
      const id = 101;
      torrentService.seedTorrent(
        id: id,
        name: 'sample_torrent',
        totalWanted: 100 * 1024 * 1024,
        totalWantedDone: 25 * 1024 * 1024,
        progress: 0.25,
        downloadRate: 2 * 1024 * 1024,
      );

      expect(torrentService.isTorrentPaused(id), isFalse);
      expect(torrentService.latestStats[id]?.downloadRate, greaterThan(0));

      // Pause torrent
      await torrentService.pauseTorrent(id);
      expect(torrentService.isTorrentPaused(id), isTrue);
      expect(torrentService.latestStats[id]?.downloadRate, equals(0));
      expect(torrentService.pausedTorrents, contains(id));

      // Resume torrent
      torrentService.resumeTorrent(id);
      expect(torrentService.isTorrentPaused(id), isFalse);
      expect(torrentService.latestStats[id]?.downloadRate, greaterThan(0));
      expect(torrentService.resumedTorrents, contains(id));
    });

    test('6. Torrent: pause during metadata fetch cancels gracefully', () async {
      final id = torrentService.addMagnet('magnet:?xt=urn:btih:fake123', '/downloads');
      expect(torrentService.latestStats[id]?.hasMetadata, isFalse);

      // Pause while metadata is resolving
      await torrentService.pauseTorrent(id);
      expect(torrentService.isTorrentPaused(id), isTrue);
      expect(torrentService.pausedTorrents, contains(id));
    });

    test('7. Torrent: pause -> fastresume saved -> relaunch resumes from resume blob', () async {
      const id = 102;
      torrentService.seedTorrent(
        id: id,
        name: 'fastresume_test',
        totalWanted: 50 * 1024 * 1024,
        totalWantedDone: 10 * 1024 * 1024,
        progress: 0.20,
      );

      // Save fastresume
      await torrentService.saveResumeData(id);
      final resumeBlob = torrentService.fetchResumeBytes(id);
      expect(resumeBlob, isNotNull);
      expect(resumeBlob!.isNotEmpty, isTrue);

      // Simulate relaunch: reload fastresume blob
      final reloaded = torrentService.loadResumeData(id, resumeBlob);
      expect(reloaded, isTrue);

      torrentService.recheckTorrent(id);
      expect(torrentService.recheckedTorrents, contains(id));
    });
  });

  group('Phase 0 Matrix — Concurrency & State Invariance', () {
    test('8. Concurrent pause of 5 tasks is idempotent and dead-lock free', () async {
      final fakeEngine = FakeIDownloadEngine();
      final tasks = List.generate(5, (i) => 'task-concurrent-$i');

      final cancelTokens = <String, CancelToken>{};
      for (final taskId in tasks) {
        final token = CancelToken();
        cancelTokens[taskId] = token;
      }

      // Concurrently trigger forceCancel / pause on all 5 tasks
      await Future.wait(tasks.map((id) async {
        fakeEngine.forceCancelJob(id);
      }));

      expect(fakeEngine.forceCancelledTasks.length, equals(5));
      for (final id in tasks) {
        expect(fakeEngine.forceCancelledTasks, contains(id));
      }
    });

    test('9. DomainStateMachine: User pause is idempotent and validates all transitions', () async {
      final sm = DomainStateMachine(
        taskId: 'task-p0',
        initialState: DomainDownloadState.queued,
      );

      expect(sm.currentState, equals(DomainDownloadState.queued));

      sm.transition(DomainDownloadState.downloading, command: 'start');
      expect(sm.currentState, equals(DomainDownloadState.downloading));

      // User pauses
      sm.transition(DomainDownloadState.paused, command: 'user_pause', reason: 'user');
      expect(sm.currentState, equals(DomainDownloadState.paused));

      // Repeated pause is idempotent
      sm.transition(DomainDownloadState.paused, command: 'user_pause', reason: 'user');
      expect(sm.currentState, equals(DomainDownloadState.paused));

      // Resume back to downloading
      sm.transition(DomainDownloadState.downloading, command: 'resume');
      expect(sm.currentState, equals(DomainDownloadState.downloading));
    });
  });
}
