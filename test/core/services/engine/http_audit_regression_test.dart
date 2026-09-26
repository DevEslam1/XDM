import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:dmx/core/services/engines/http_download_engine.dart';
import 'package:dmx/core/services/mirror/mirror_selector.dart';
import 'package:flutter_test/flutter_test.dart';

class _StreamProbeAdapter implements HttpClientAdapter {
  _StreamProbeAdapter(this.statusCode, this.chunksToYield);

  final int statusCode;
  final List<Uint8List> chunksToYield;
  bool streamCancelled = false;
  int yieldedCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final controller = StreamController<Uint8List>();
    controller.onListen = () async {
      for (final chunk in chunksToYield) {
        if (controller.isClosed) break;
        controller.add(chunk);
        yieldedCount++;
        await Future.delayed(const Duration(milliseconds: 10));
      }
      if (!controller.isClosed) {
        await controller.close();
      }
    };
    controller.onCancel = () {
      streamCancelled = true;
    };

    return ResponseBody(
      controller.stream,
      statusCode,
      headers: {
        'content-length': ['10000000'],
        'etag': ['"test-etag"'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Section A & C: State Tolerance & Journal Reconciliation', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dmx_http_audit_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
        'TransferState.tryParseV3 tolerates empty chunks list without returning null',
        () {
      final json = {
        'version': 3,
        'url': 'https://example.com/file.rar',
        'totalSize': 1234567,
        'threadCount': 1,
        'etag': '"abc-123"',
        'lastModified': 'Wed, 21 Oct 2025 07:28:00 GMT',
        'chunks': <Map<String, dynamic>>[],
      };

      final state = TransferState.tryParseV3(json);
      expect(state, isNotNull);
      expect(state!.chunks, isEmpty);
      expect(state.totalSize, 1234567);
      expect(state.threadCount, 1);
      expect(state.url, 'https://example.com/file.rar');
      expect(state.etag, '"abc-123"');
      expect(state.downloadedBytes, 0);
    });

    test(
        'StateStore.loadOrCreate does not corrupt or backup valid empty-chunk JSON',
        () async {
      final tempFilePath = '${tempDir.path}/test_download.tmp';
      final statePath = '$tempFilePath.dmxstate';
      final backupPath = '$statePath.bak';

      final jsonContent = jsonEncode({
        'version': 3,
        'url': 'https://example.com/archive.zip',
        'totalSize': 5000000,
        'threadCount': 1,
        'chunks': <Map<String, dynamic>>[],
      });
      await File(statePath).writeAsString(jsonContent);

      final loadResult = await StateStore.loadOrCreate(
        tempFilePath,
        url: 'https://example.com/archive.zip',
        threadCount: 1,
        knownFileSize: 5000000,
      );

      // Must not create backup file or wipe state
      expect(File(backupPath).existsSync(), isFalse);
      expect(loadResult.state.totalSize, 5000000);
      expect(loadResult.state.url, 'https://example.com/archive.zip');
    });

    test('Single-stream disk reconciliation for single-thread empty chunks',
        () async {
      final tempFilePath = '${tempDir.path}/single.tmp';
      final statePath = '$tempFilePath.dmxstate';

      // Create a 2MB temp file on disk
      final tempFile = File(tempFilePath);
      await tempFile.writeAsBytes(List<int>.filled(2 * 1024 * 1024, 0x41));

      final jsonContent = jsonEncode({
        'version': 3,
        'url': 'https://example.com/single.iso',
        'totalSize': 10 * 1024 * 1024,
        'threadCount': 1,
        'chunks': <Map<String, dynamic>>[],
      });
      await File(statePath).writeAsString(jsonContent);

      final loadResult = await StateStore.loadOrCreate(
        tempFilePath,
        url: 'https://example.com/single.iso',
        threadCount: 1,
        knownFileSize: 10 * 1024 * 1024,
      );

      expect(loadResult.state.chunks.length, 1);
      expect(loadResult.state.chunks.first.downloaded, 2 * 1024 * 1024);
      expect(loadResult.state.downloadedBytes, 2 * 1024 * 1024);
    });
  });

  group('Section B: Mirror Selector De-Racing', () {
    test('MirrorFailover.advance(failedUrl) de-races parallel worker failures',
        () {
      final mirrors = [
        'https://mirror1.example.com/file.bin',
        'https://mirror2.example.com/file.bin',
        'https://mirror3.example.com/file.bin',
      ];
      final failover = MirrorFailover(mirrors);
      expect(failover.activeUrl, 'https://mirror1.example.com/file.bin');

      // Worker 1 fails on mirror1 and calls advance with failedUrl
      final next1 = failover.advance('https://mirror1.example.com/file.bin');
      expect(next1, 'https://mirror2.example.com/file.bin');
      expect(failover.activeUrl, 'https://mirror2.example.com/file.bin');
      expect(failover.mirrorSwitches, 1);

      // Worker 2 also failed on mirror1 slightly later and calls advance with mirror1
      final next2 = failover.advance('https://mirror1.example.com/file.bin');
      // Should NOT advance again to mirror3! It should return current activeUrl (mirror2)
      expect(next2, 'https://mirror2.example.com/file.bin');
      expect(failover.activeUrl, 'https://mirror2.example.com/file.bin');
      expect(failover.mirrorSwitches, 1);

      // Now a real failure on mirror2 advances to mirror3
      final next3 = failover.advance('https://mirror2.example.com/file.bin');
      expect(next3, 'https://mirror3.example.com/file.bin');
      expect(failover.activeUrl, 'https://mirror3.example.com/file.bin');
      expect(failover.mirrorSwitches, 2);
    });
  });

  group('Section C: Range Probe Stream Cancellation on HTTP 200', () {
    test(
        '_verifyServerIdentity immediately cancels stream when server returns 200',
        () async {
      final receivePort = ReceivePort();
      const cmd = DownloadCommand(
        taskId: 'probe-test-200',
        url: 'https://example.com/largefile.zip',
        punyUrl: 'https://example.com/largefile.zip',
        tempFilePath: 'build/probe_200.tmp',
        localFilePath: 'build/probe_200.zip',
        threadCount: 1,
        knownFileSize: 10000000,
        supportsResume: true,
      );

      final job = HttpTransferJob(cmd, receivePort.sendPort);
      job.stateForTesting = TransferState(
        totalSize: 10000000,
        threadCount: 1,
        etag: '"test-etag"',
        chunks: ChunkScheduler.singleStream(10000000),
      );

      final adapter = _StreamProbeAdapter(200, [
        Uint8List(1024),
        Uint8List(1024),
        Uint8List(1024),
      ]);
      final dio = Dio();
      dio.httpClientAdapter = adapter;

      // Invalidate identity cache to force probe execution
      HttpTransferJob.clearIdentityCache();

      // Calling executeDownload will run _verifyServerIdentity first
      try {
        await job.executeDownload(dio);
      } catch (_) {
        // Expected because mock adapter does not implement full download flow
      }

      // Verify stream was cancelled and did not drain all chunks
      expect(adapter.streamCancelled, isTrue);

      receivePort.close();
    });
  });

  group('Section A: 416 Total Size Discovery & Completion', () {
    test('handle416 updates chunk boundaries accurately when serverTotal is known',
        () {
      final chunk = ChunkState(start: 0, end: 999999, downloaded: 1000000);
      final handled = HttpTransferJob.handle416(chunk, 1000000);
      expect(handled.isComplete, isTrue);
      expect(handled.downloaded, 1000000);
    });
  });
}
