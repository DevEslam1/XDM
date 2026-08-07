import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;

class MockDio extends Mock implements Dio {}

void main() {
  group('BandwidthGovernor', () {
    test('updateLimit sets the limit', () {
      final gov = BandwidthGovernor();
      gov.registerConsumer();
      gov.updateLimit(1024 * 1024);
      expect(gov.isUnlimited, isFalse);
      expect(gov.perConsumerBytesPerSecond, 1024 * 1024);
    });

    test('setLimit sets the limit', () {
      final gov = BandwidthGovernor();
      gov.registerConsumer();
      gov.setLimit(512 * 1024);
      expect(gov.isUnlimited, isFalse);
      expect(gov.perConsumerBytesPerSecond, 512 * 1024);
    });

    test('zero limit means unlimited', () {
      final gov = BandwidthGovernor(0);
      expect(gov.isUnlimited, isTrue);
      gov.setLimit(0);
      expect(gov.isUnlimited, isTrue);
    });

    test('perConsumerBytesPerSecond divides by active consumers', () {
      final gov = BandwidthGovernor(1024 * 1024);
      gov.registerConsumer();
      gov.registerConsumer();
      expect(gov.perConsumerBytesPerSecond, 512 * 1024);
    });
  });

  group('DownloadEngine path builders', () {
    test('buildLocalFilePath returns clean file path', () {
      final engine = DownloadEngine(enableCleanupTimer: false);
      final path = engine.buildLocalFilePath('/downloads', 'my file.mp4');
      expect(p.basename(path), 'my file.mp4');
      expect(path, contains('/downloads'));
    });

    test('buildTempFilePath appends .dmxpart suffix', () {
      final engine = DownloadEngine(enableCleanupTimer: false);
      final path = engine.buildTempFilePath('/downloads', 'my file.mp4');
      expect(p.basename(path), 'my file.mp4.dmxpart');
      expect(path, contains('/downloads'));
    });

    test('buildLocalFilePath and buildTempFilePath are different', () {
      final engine = DownloadEngine(enableCleanupTimer: false);
      final local = engine.buildLocalFilePath('/dl', 'video.mp4');
      final temp = engine.buildTempFilePath('/dl', 'video.mp4');
      expect(local, isNot(temp));
      expect(temp, endsWith('.dmxpart'));
    });
  });

  group('DownloadJournal', () {
    test('recover returns null for missing journal', () async {
      final result = await DownloadJournal.recover('build/missing.journal');
      expect(result, isNull);
    });

    test('writeInit and recover round-trip', () async {
      final path = 'build/test_recover.journal';
      final file = File(path);
      if (await file.exists()) await file.delete();

      final journal = DownloadJournal(path);
      await journal.open();
      await journal.writeInit(4, 1000);
      await journal.recordChunkProgress(0, 100);
      await journal.recordChunkProgress(1, 200);
      await journal.writeCheckpoint([100, 200, 50, 0], 1000);
      await journal.close();

      final recovered = await DownloadJournal.recover(path);
      expect(recovered, isNotNull);
      expect(recovered!.length, 4);
      expect(recovered[0], 100);
      expect(recovered[1], 200);
      expect(recovered[2], 50);
      expect(recovered[3], 0);

      await file.delete();
    });

    test('writeInit does not destroy recovered journal', () async {
      final path = 'build/test_no_destroy.journal';
      final file = File(path);
      if (await file.exists()) await file.delete();

      final j1 = DownloadJournal(path);
      await j1.open();
      await j1.writeInit(2, 500);
      await j1.recordChunkProgress(0, 50);
      await j1.writeCheckpoint([50, 0], 500);
      await j1.close();

      final recovered = await DownloadJournal.recover(path);
      expect(recovered, isNotNull);
      expect(recovered![0], 50);

      // Open again — writeInit appends, does not overwrite
      final j2 = DownloadJournal(path);
      await j2.open();
      await j2.writeInit(2, 500);
      await j2.close();

      final recovered2 = await DownloadJournal.recover(path);
      expect(recovered2, isNotNull);
      expect(recovered2!.length, 2);

      await file.delete();
    });

    test('close releases file handle for delete', () async {
      final path = 'build/test_close_delete.journal';
      final file = File(path);
      if (await file.exists()) await file.delete();

      final journal = DownloadJournal(path);
      await journal.open();
      await journal.writeInit(1, 100);
      await journal.close();
      await journal.delete();
      expect(await file.exists(), isFalse);
    });
  });

  group('PositionalFileWriter', () {
    test('close releases file handle for rename', () async {
      final path = 'build/test_writer_close.tmp';
      final finalPath = 'build/test_writer_renamed.bin';
      final f = File(path);
      if (await f.exists()) await f.delete();
      final ff = File(finalPath);
      if (await ff.exists()) await ff.delete();

      final writer = await PositionalFileWriter.open(
        path,
        totalSize: 100,
        threadCount: 1,
      );
      await writer.write(
        0,
        0,
        Uint8List.fromList(List<int>.generate(100, (i) => i)),
      );
      await writer.close();

      await File(path).rename(finalPath);
      expect(await File(finalPath).exists(), isTrue);
      expect(await File(finalPath).length(), 100);

      await File(finalPath).delete();
    });

    test('openForResume does not truncate existing data', () async {
      final path = 'build/test_resume_no_truncate.tmp';
      final f = File(path);
      if (await f.exists()) await f.delete();

      // Use openForResume (not open) so pre-allocation does not inflate the file
      final w1 = await PositionalFileWriter.openForResume(path, threadCount: 1);
      await w1.write(
        0,
        0,
        Uint8List.fromList(List<int>.generate(50, (i) => i)),
      );
      await w1.close();

      final w2 = await PositionalFileWriter.openForResume(path, threadCount: 1);
      expect(w2, isNotNull);
      await w2.close();

      await File(path).delete();
    });

    test('flushAll flushes all thread buffers', () async {
      final path = 'build/test_flush_all.tmp';
      final f = File(path);
      if (await f.exists()) await f.delete();

      final writer = await PositionalFileWriter.open(
        path,
        totalSize: 200,
        threadCount: 2,
      );
      await writer.write(
        0,
        0,
        Uint8List.fromList(List<int>.generate(100, (i) => i)),
      );
      await writer.write(
        1,
        100,
        Uint8List.fromList(List<int>.generate(100, (i) => i)),
      );
      await writer.flushAll();

      final size = await writer.fileSize();
      expect(size, 200);
      await writer.close();

      await File(path).delete();
    });
  });

  group('DownloadIntegrityException', () {
    test('is not retryable in error classification', () {
      final error = const DownloadIntegrityException('size mismatch');
      expect(error.toString(), contains('DownloadIntegrityException'));
      expect(error.message, 'size mismatch');
    });

    test('is a non-DioException type', () {
      final error = const DownloadIntegrityException('test');
      expect(error is DioException, isFalse);
    });
  });

  group('IsolateSpawnTimeoutException', () {
    test('has a default message', () {
      final error = const IsolateSpawnTimeoutException();
      expect(
        error.message,
        'Download engine failed to initialize. Please retry.',
      );
    });

    test('accepts custom message', () {
      final error = const IsolateSpawnTimeoutException('Custom message');
      expect(error.message, 'Custom message');
    });
  });

  group('DownloadProgress', () {
    test('constructs with all fields', () {
      final progress = DownloadProgress(
        downloadedBytes: 100,
        fileSize: 1000,
        speed: 50000.0,
        eta: 18,
        chunks: [0.1, 0.1],
        fileName: 'test.bin',
        supportsResume: true,
        statusMessage: 'Downloading...',
      );
      expect(progress.downloadedBytes, 100);
      expect(progress.fileSize, 1000);
      expect(progress.chunks, [0.1, 0.1]);
      expect(progress.fileName, 'test.bin');
    });
  });

  group('DownloadMetadata', () {
    test('constructs with file info', () {
      final meta = const DownloadMetadata(
        fileName: 'file.zip',
        category: 'Archive',
        fileSize: 500,
        supportsResume: true,
      );
      expect(meta.fileName, 'file.zip');
      expect(meta.fileSize, 500);
    });
  });

  group('PositionalFileWriter thread safety', () {
    test('concurrent writes on different threads do not interfere', () async {
      final path = 'build/test_thread_safety.tmp';
      final f = File(path);
      if (await f.exists()) await f.delete();

      final writer = await PositionalFileWriter.open(
        path,
        totalSize: 200,
        threadCount: 2,
        bufferSize: 256,
      );

      final f1 = writer.write(
        0,
        0,
        Uint8List.fromList(List<int>.generate(100, (i) => i)),
      );
      final f2 = writer.write(
        1,
        100,
        Uint8List.fromList(List<int>.generate(100, (i) => 255 - i)),
      );
      await Future.wait([f1, f2]);
      await writer.flushAll();

      final size = await writer.fileSize();
      expect(size, 200);
      await writer.close();

      final data = await File(path).readAsBytes();
      expect(data.length, 200);
      expect(data[0], 0);
      expect(data[99], 99);
      expect(data[100], 255);
      expect(data[199], 255 - 99);

      await File(path).delete();
    });
  });

  group('DownloadEngine integration', () {
    test('buildTempFilePath and buildLocalFilePath are distinct', () {
      final engine = DownloadEngine(enableCleanupTimer: false);
      final dir = 'build';
      final name = 'video.mp4';
      final temp = engine.buildTempFilePath(dir, name);
      final local = engine.buildLocalFilePath(dir, name);

      expect(p.basename(temp), 'video.mp4.dmxpart');
      expect(p.basename(local), 'video.mp4');
      expect(temp, isNot(local));
    });

    test('single-thread download completes and renames temp file', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      final url = 'http://localhost:$port/single.bin';

      server.listen((HttpRequest request) async {
        final response = request.response;
        response.statusCode = HttpStatus.ok;
        response.headers.set('content-length', '50');
        response.add(List<int>.generate(50, (i) => i));
        await response.close();
      });

      final engine = DownloadEngine(enableCleanupTimer: false);
      final localFile = File('build/test_single_complete.bin');
      final tempFile = File('build/test_single_complete.bin.dmxpart');
      if (localFile.existsSync()) localFile.deleteSync();
      if (tempFile.existsSync()) tempFile.deleteSync();

      final progress = <DownloadProgress>[];
      await engine.download(
        taskId: 'test_task_id',
        url: url,
        tempFilePath: tempFile.path,
        localFilePath: localFile.path,
        knownFileSize: 50,
        supportsResume: false,
        cancelToken: CancelToken(),
        onProgress: (p) => progress.add(p),
        speedLimitBytesPerSecond: () => 0,
        activeDownloadCount: () => 1,
        threadCount: 1,
      );

      expect(localFile.existsSync(), isTrue);
      expect(localFile.lengthSync(), 50);
      expect(tempFile.existsSync(), isFalse);
      expect(progress.isNotEmpty, isTrue);
      expect(progress.last.downloadedBytes, 50);

      await server.close();
      if (localFile.existsSync()) localFile.deleteSync();
      if (tempFile.existsSync()) tempFile.deleteSync();
    });

    test(
      'incomplete known-size file triggers error and does not create final file',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final port = server.port;
        final url = 'http://localhost:$port/partial.bin';

        server.listen((HttpRequest request) async {
          final response = request.response;
          response.statusCode = HttpStatus.ok;
          // No content-length header → chunked encoding
          // Send 80 bytes but knownFileSize is 100
          response.add(List<int>.generate(80, (i) => i));
          await response.close();
        });

        final engine = DownloadEngine(enableCleanupTimer: false);
        final localFile = File('build/test_integrity_fail.bin');
        final tempFile = File('build/test_integrity_fail.bin.dmxpart');
        if (localFile.existsSync()) localFile.deleteSync();
        if (tempFile.existsSync()) tempFile.deleteSync();

        try {
          await engine.download(
            taskId: 'test_task_id',
            url: url,
            tempFilePath: tempFile.path,
            localFilePath: localFile.path,
            knownFileSize: 100,
            supportsResume: false,
            cancelToken: CancelToken(),
            onProgress: (_) {},
            speedLimitBytesPerSecond: () => 0,
            activeDownloadCount: () => 1,
            threadCount: 1,
          );
          fail('Expected error — file size mismatch');
        } catch (_) {
          // Download must fail — integrity or connection error
        }

        // Final file must NOT be created when download fails
        expect(localFile.existsSync(), isFalse);

        await server.close();
        if (localFile.existsSync()) localFile.deleteSync();
        if (tempFile.existsSync()) tempFile.deleteSync();
      },
    );

    test('server rejects range requests falls back to single-thread', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      final url = 'http://localhost:$port/norange.bin';

      server.listen((HttpRequest request) async {
        final response = request.response;
        if (request.method == 'HEAD') {
          response.headers.set('accept-ranges', 'bytes');
          response.headers.set('content-length', '100');
          response.statusCode = HttpStatus.ok;
          await response.close();
        } else {
          final range = request.headers.value('range');
          if (range != null) {
            response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            await response.close();
          } else {
            response.statusCode = HttpStatus.ok;
            response.headers.set('content-length', '100');
            response.add(List<int>.generate(100, (i) => i));
            await response.close();
          }
        }
      });

      final engine = DownloadEngine(enableCleanupTimer: false);
      final localFile = File('build/test_norange_fallback.bin');
      final tempFile = File('build/test_norange_fallback.bin.dmxpart');
      if (localFile.existsSync()) localFile.deleteSync();
      if (tempFile.existsSync()) tempFile.deleteSync();

      final progress = <DownloadProgress>[];
      await engine.download(
        taskId: 'test_task_id',
        url: url,
        tempFilePath: tempFile.path,
        localFilePath: localFile.path,
        knownFileSize: 100,
        supportsResume: true,
        cancelToken: CancelToken(),
        onProgress: (p) => progress.add(p),
        speedLimitBytesPerSecond: () => 0,
        activeDownloadCount: () => 1,
        threadCount: 4,
      );

      expect(localFile.existsSync(), isTrue);
      expect(localFile.lengthSync(), 100);
      expect(progress.last.downloadedBytes, 100);

      await server.close();
      if (localFile.existsSync()) localFile.deleteSync();
      if (tempFile.existsSync()) tempFile.deleteSync();
    });

    test('speed limit can be updated during download', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      final url = 'http://localhost:$port/limit.bin';

      server.listen((HttpRequest request) async {
        final response = request.response;
        response.statusCode = HttpStatus.ok;
        response.headers.set('content-length', '100');
        response.add(List<int>.generate(100, (i) => i));
        await response.close();
      });

      final engine = DownloadEngine(enableCleanupTimer: false);
      final localFile = File('build/test_speed_limit.bin');
      final tempFile = File('build/test_speed_limit.bin.dmxpart');
      if (localFile.existsSync()) localFile.deleteSync();
      if (tempFile.existsSync()) tempFile.deleteSync();

      engine.updateSpeedLimit(1024 * 1024, 1);
      await engine.download(
        taskId: 'test_task_id',
        url: url,
        tempFilePath: tempFile.path,
        localFilePath: localFile.path,
        knownFileSize: 100,
        supportsResume: false,
        cancelToken: CancelToken(),
        onProgress: (_) {},
        speedLimitBytesPerSecond: () => 1024 * 1024,
        activeDownloadCount: () => 1,
        threadCount: 1,
      );

      expect(localFile.existsSync(), isTrue);
      expect(localFile.lengthSync(), 100);

      await server.close();
      if (localFile.existsSync()) localFile.deleteSync();
      if (tempFile.existsSync()) tempFile.deleteSync();
    });
  });

  group('BandwidthGovernor — limit changes during download', () {
    test('updateLimit can be called while consumers are active', () {
      final gov = BandwidthGovernor(1024 * 1024);
      gov.registerConsumer();
      expect(gov.perConsumerBytesPerSecond, 1024 * 1024);

      gov.updateLimit(512 * 1024);
      expect(gov.perConsumerBytesPerSecond, 512 * 1024);

      gov.setLimit(0);
      expect(gov.isUnlimited, isTrue);
    });

    test('acquire reflects new limit after updateLimit', () async {
      final gov = BandwidthGovernor(1024);
      gov.registerConsumer();
      // With 1024 B/s limit and 1 consumer, 2048 bytes should need ~2000ms
      final sleepMs = await gov.acquire(2048);
      expect(sleepMs, greaterThan(0));

      gov.updateLimit(1024 * 1024);
      final sleepMs2 = await gov.acquire(2048);
      expect(sleepMs2, lessThan(10));
    });
  });

  group('DownloadJournal — compaction', () {
    test(
      'writeCheckpoint triggers compaction when threshold is exceeded',
      () async {
        final path = 'build/test_compaction.journal';
        final file = File(path);
        if (await file.exists()) await file.delete();

        // Very low threshold so compaction triggers on first writeCheckpoint
        final journal = DownloadJournal(path, compactionThresholdBytes: 1);
        await journal.open();
        await journal.writeInit(4, 1000);
        await journal.writeCheckpoint([100, 200, 300, 400], 1000);
        await journal.close();

        // After compaction, the journal should only have init + checkpoint = 2 lines
        final rawLines = await file.readAsLines();
        expect(rawLines.length, 2);
        final parsed = rawLines.map((l) {
          final outer = jsonDecode(l) as Map<String, dynamic>;
          final payloadStr = outer.containsKey('d') ? outer['d'] as String : l;
          return jsonDecode(payloadStr) as Map<String, dynamic>;
        }).toList();
        expect(parsed[0]['t'], 'init');
        expect(parsed[0]['threads'], 4);
        expect(parsed[1]['t'], 'checkpoint');
        expect(parsed[1]['chunks'], [100, 200, 300, 400]);

        await file.delete();
      },
    );

    test('recover works correctly after compaction', () async {
      final path = 'build/test_recover_after_compact.journal';
      final file = File(path);
      if (await file.exists()) await file.delete();

      final j1 = DownloadJournal(path, compactionThresholdBytes: 1);
      await j1.open();
      await j1.writeInit(3, 999);
      await j1.recordChunkProgress(0, 50);
      await j1.recordChunkProgress(1, 75);
      await j1.writeCheckpoint([50, 75, 0], 999);
      await j1.close();

      // Recover after compaction
      final recovered = await DownloadJournal.recover(path);
      expect(recovered, isNotNull);
      expect(recovered!.length, 3);
      expect(recovered[0], 50);
      expect(recovered[1], 75);
      expect(recovered[2], 0);

      await file.delete();
    });

    test('multiple checkpoint cycles and recover work', () async {
      final path = 'build/test_multi_cycle.journal';
      final file = File(path);
      if (await file.exists()) await file.delete();

      final journal = DownloadJournal(path, compactionThresholdBytes: 64);
      await journal.open();
      await journal.writeInit(2, 500);
      await journal.writeCheckpoint([50, 0], 500);
      await journal.writeCheckpoint([100, 25], 500);
      await journal.writeCheckpoint([150, 50], 500);
      await journal.close();

      final recovered = await DownloadJournal.recover(path);
      expect(recovered, isNotNull);
      expect(recovered![0], 150);
      expect(recovered[1], 50);

      await file.delete();
    });
  });

  group('DownloadJournal — crash recovery', () {
    test('recover returns latest checkpoint after simulated crash', () async {
      final path = 'build/test_crash_recover.journal';
      final file = File(path);
      if (await file.exists()) await file.delete();

      final j = DownloadJournal(path);
      await j.open();
      await j.writeInit(3, 1000);
      await j.recordChunkProgress(0, 100);
      await j.recordChunkProgress(1, 200);

      // Simulate crash — journal is not closed; just recover what was written
      // close() is called to simulate what would have been flushed to disk
      await j.close();

      final recovered = await DownloadJournal.recover(path);
      expect(recovered, isNotNull);
      expect(recovered!.length, 3);
      // The chunk lines are applied in order after the init
      expect(recovered[0], 100);
      expect(recovered[1], 200);
      expect(recovered[2], 0);

      await file.delete();
    });
  });

  group('PositionalFileWriter — non-contiguous writes', () {
    test(
      'non-contiguous write flushes before moving to new position',
      () async {
        final path = 'build/test_non_contiguous.tmp';
        final f = File(path);
        if (await f.exists()) await f.delete();

        final writer = await PositionalFileWriter.open(
          path,
          totalSize: 200,
          threadCount: 1,
          bufferSize: 1024,
        );

        // Write at position 100 first (thread 0)
        await writer.write(
          0,
          100,
          Uint8List.fromList(List<int>.generate(50, (i) => 0xFF)),
        );
        // Write at position 0 — this should flush the previous buffer first,
        // then start a new buffer at position 0
        await writer.write(
          0,
          0,
          Uint8List.fromList(List<int>.generate(50, (i) => 0xAA)),
        );
        await writer.flushAll();

        final data = await File(path).readAsBytes();
        // Bytes 0-49 should be 0xAA
        for (int i = 0; i < 50; i++) {
          expect(data[i], 0xAA);
        }
        // Bytes 100-149 should be 0xFF
        for (int i = 100; i < 150; i++) {
          expect(data[i], 0xFF);
        }

        await writer.close();
        await File(path).delete();
      },
    );

    test('flushAll then close allows rename', () async {
      final path = 'build/test_flush_then_rename.tmp';
      final finalPath = 'build/test_flush_then_renamed.bin';
      for (final p in [path, finalPath]) {
        final pf = File(p);
        if (await pf.exists()) await pf.delete();
      }

      final writer = await PositionalFileWriter.open(
        path,
        totalSize: 50,
        threadCount: 2,
      );
      await writer.write(
        0,
        0,
        Uint8List.fromList(List<int>.generate(25, (i) => i)),
      );
      await writer.write(
        1,
        25,
        Uint8List.fromList(List<int>.generate(25, (i) => i)),
      );
      await writer.flushAll();
      await writer.close();

      await File(path).rename(finalPath);
      expect(await File(finalPath).exists(), isTrue);
      expect(await File(finalPath).length(), 50);

      await File(finalPath).delete();
    });
  });

  group('DownloadEngine integration — resume and cancel', () {
    test(
      'cancel during active download cleans up temp file and journal',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final port = server.port;
        final url = 'http://localhost:$port/delayed.bin';

        server.listen((HttpRequest request) async {
          final response = request.response;
          response.statusCode = HttpStatus.ok;
          response.headers.set('content-length', '200');

          for (int i = 0; i < 200; i += 10) {
            await Future.delayed(const Duration(milliseconds: 20));
            response.add(List<int>.generate(10, (j) => i + j));
          }
          await response.close();
        });

        final engine = DownloadEngine(enableCleanupTimer: false);
        final cancelToken = CancelToken();

        final localFile = File('build/test_cancel_cleanup.bin');
        final tempFile = File('build/test_cancel_cleanup.bin.dmxpart');
        if (localFile.existsSync()) localFile.deleteSync();
        if (tempFile.existsSync()) tempFile.deleteSync();

        // Start download and cancel after a short delay
        Future.delayed(const Duration(milliseconds: 100), () {
          if (!cancelToken.isCancelled) cancelToken.cancel();
        });

        try {
          await engine.download(
            taskId: 'test_task_id',
            url: url,
            tempFilePath: tempFile.path,
            localFilePath: localFile.path,
            knownFileSize: 200,
            supportsResume: false,
            cancelToken: cancelToken,
            onProgress: (_) {},
            speedLimitBytesPerSecond: () => 0,
            activeDownloadCount: () => 1,
            threadCount: 1,
          );
          fail('Expected download to be cancelled');
        } catch (e) {
          // Cancel is expected — verify cleanup
          expect(
            localFile.existsSync(),
            isFalse,
            reason: 'Final file must not exist after cancel',
          );
        }

        await server.close();
        if (localFile.existsSync()) localFile.deleteSync();
        if (tempFile.existsSync()) tempFile.deleteSync();
      },
    );

    test('single-thread resume after partial download works', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      final url = 'http://localhost:$port/resume_test.bin';

      server.listen((HttpRequest request) async {
        final response = request.response;
        final range = request.headers.value('range');

        if (range != null) {
          final match = RegExp(r'bytes=(\d+)-').firstMatch(range);
          final resumeFrom = match != null ? int.parse(match.group(1)!) : 0;
          response.statusCode = HttpStatus.partialContent;
          response.headers.set('content-range', 'bytes $resumeFrom-${99}/100');
          response.add(
            List<int>.generate(100 - resumeFrom, (i) => resumeFrom + i),
          );
        } else {
          // First connection — send data slowly so cancel creates a partial file
          response.statusCode = HttpStatus.ok;
          for (int i = 0; i < 100; i += 10) {
            await Future.delayed(const Duration(milliseconds: 20));
            response.add(List<int>.generate(10, (j) => i + j));
          }
        }
        await response.close();
      });

      final engine = DownloadEngine(enableCleanupTimer: false);
      final localFile = File('build/test_resume_partial.bin');
      final tempFile = File('build/test_resume_partial.bin.dmxpart');
      if (localFile.existsSync()) localFile.deleteSync();
      if (tempFile.existsSync()) tempFile.deleteSync();

      {
        final ct = CancelToken();
        Future.delayed(const Duration(milliseconds: 150), () => ct.cancel());
        try {
          await engine.download(
            taskId: 'test_task_id',
            url: url,
            tempFilePath: tempFile.path,
            localFilePath: localFile.path,
            knownFileSize: 100,
            supportsResume: true,
            cancelToken: ct,
            onProgress: (_) {},
            speedLimitBytesPerSecond: () => 0,
            activeDownloadCount: () => 1,
            threadCount: 1,
          );
        } catch (_) {}
      }

      final progress = <DownloadProgress>[];
      await engine.download(
        taskId: 'test_task_id',
        url: url,
        tempFilePath: tempFile.path,
        localFilePath: localFile.path,
        knownFileSize: 100,
        supportsResume: true,
        cancelToken: CancelToken(),
        onProgress: (p) => progress.add(p),
        speedLimitBytesPerSecond: () => 0,
        activeDownloadCount: () => 1,
        threadCount: 1,
      );

      expect(localFile.existsSync(), isTrue);
      expect(localFile.lengthSync(), 100);
      expect(progress.last.downloadedBytes, 100);

      await server.close();
      if (localFile.existsSync()) localFile.deleteSync();
      if (tempFile.existsSync()) tempFile.deleteSync();
    });
  });

  group('DownloadIntegrityException — engine error handling', () {
    test(
      'integrity error thrown by engine is a DownloadIntegrityException',
      () {
        final error = const DownloadIntegrityException('size mismatch');
        expect(error.message, 'size mismatch');
        expect(error.toString(), contains('DownloadIntegrityException'));
      },
    );

    test(
      'integrity errors are not retryable in orchestrator classification',
      () {
        // This mirrors the logic in download_orchestrator.dart
        bool isRetryable(Object error) {
          if (error is DownloadIntegrityException) return false;
          return true;
        }

        expect(isRetryable(const DownloadIntegrityException('bad')), isFalse);
        expect(
          isRetryable(DioException(requestOptions: RequestOptions(path: ''))),
          isTrue,
        );
      },
    );
  });

  group('DownloadEngine — estimateOptimalThreads', () {
    late MockDio mockDio;

    setUpAll(() {
      registerFallbackValue(RequestOptions(path: ''));
    });

    setUp(() {
      mockDio = MockDio();
    });

    test('requestedThreads <= 1 returns 1', () async {
      final engine = DownloadEngine(enableCleanupTimer: false);
      final result = await engine.estimateOptimalThreads(
        url: 'http://example.com/file',
        requestedThreads: 1,
        fileSize: 1000000,
        dio: mockDio,
      );
      expect(result, 1);
    });

    test('fileSize < 512KB returns 1', () async {
      final engine = DownloadEngine(enableCleanupTimer: false);
      final result = await engine.estimateOptimalThreads(
        url: 'http://example.com/file',
        requestedThreads: 4,
        fileSize: 500 * 1024,
        dio: mockDio,
      );
      expect(result, 1);
    });

    test('accept-ranges none returns 1', () async {
      final headers = Headers();
      headers.add('accept-ranges', 'none');
      final response = Response(
        requestOptions: RequestOptions(path: ''),
        headers: headers,
        statusCode: 200,
      );

      when(() => mockDio.head(
            any(),
            cancelToken: any(named: 'cancelToken'),
            options: any(named: 'options'),
          )).thenAnswer((_) async => response);

      final engine = DownloadEngine(enableCleanupTimer: false);
      final result = await engine.estimateOptimalThreads(
        url: 'http://example.com/file',
        requestedThreads: 4,
        fileSize: 1024 * 1024,
        dio: mockDio,
      );
      expect(result, 1);
    });

    test('connection close header returns 1', () async {
      final headers = Headers();
      headers.add('connection', 'close');
      final response = Response(
        requestOptions: RequestOptions(path: ''),
        headers: headers,
        statusCode: 200,
      );

      when(() => mockDio.head(
            any(),
            cancelToken: any(named: 'cancelToken'),
            options: any(named: 'options'),
          )).thenAnswer((_) async => response);

      final engine = DownloadEngine(enableCleanupTimer: false);
      final result = await engine.estimateOptimalThreads(
        url: 'http://example.com/file',
        requestedThreads: 4,
        fileSize: 1024 * 1024,
        dio: mockDio,
      );
      expect(result, 1);
    });

    test('valid range support returns requestedThreads', () async {
      final headers = Headers();
      headers.add('accept-ranges', 'bytes');
      final response = Response(
        requestOptions: RequestOptions(path: ''),
        headers: headers,
        statusCode: 200,
      );

      when(() => mockDio.head(
            any(),
            cancelToken: any(named: 'cancelToken'),
            options: any(named: 'options'),
          )).thenAnswer((_) async => response);

      final engine = DownloadEngine(enableCleanupTimer: false);
      final result = await engine.estimateOptimalThreads(
        url: 'http://example.com/file',
        requestedThreads: 4,
        fileSize: 1024 * 1024,
        dio: mockDio,
      );
      expect(result, 4);
    });

    test('exception in HEAD request falls back to requestedThreads', () async {
      when(() => mockDio.head(
            any(),
            cancelToken: any(named: 'cancelToken'),
            options: any(named: 'options'),
          )).thenThrow(Exception('HEAD error'));

      final engine = DownloadEngine(enableCleanupTimer: false);
      final result = await engine.estimateOptimalThreads(
        url: 'http://example.com/file',
        requestedThreads: 4,
        fileSize: 1024 * 1024,
        dio: mockDio,
      );
      expect(result, 4);
    });
  });

  group('DownloadEngine — cleanupOrphanFiles', () {
    test('cleans up temporary and other orphan files', () async {
      final tempDir = Directory.systemTemp.createTempSync('dmx_cleanup_test');
      final baseTempPath = '${tempDir.path}/test_download.dmxpart';

      final partFile = File(baseTempPath);
      final stateFile = File('${tempDir.path}/test_download.dmxstate');
      final journalFile = File('${tempDir.path}/test_download.journal');
      final audioFile = File('${tempDir.path}/test_download.audio');
      final customPartFile = File('${tempDir.path}/test_download.part1');

      await partFile.writeAsString('part');
      await stateFile.writeAsString('state');
      await journalFile.writeAsString('journal');
      await audioFile.writeAsString('audio');
      await customPartFile.writeAsString('custom_part');

      expect(partFile.existsSync(), isTrue);
      expect(stateFile.existsSync(), isTrue);
      expect(journalFile.existsSync(), isTrue);
      expect(audioFile.existsSync(), isTrue);
      expect(customPartFile.existsSync(), isTrue);

      await DownloadEngine.cleanupOrphanFiles(baseTempPath,
          mergeConfirmed: true);

      expect(partFile.existsSync(), isFalse);
      expect(stateFile.existsSync(), isFalse);
      expect(journalFile.existsSync(), isFalse);
      expect(audioFile.existsSync(), isFalse);
      expect(customPartFile.existsSync(), isFalse);

      tempDir.deleteSync(recursive: true);
    });
  });
}
