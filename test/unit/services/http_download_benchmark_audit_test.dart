import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:dmx/core/services/engines/http_download_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('http_audit_test_');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('HTTP Download Benchmark Audit - Chunk Integrity & Resume', () {
    test(
        'loadAndReconcileState preserves physical chunk boundaries when downloadedBytes > 0',
        () async {
      final tempFilePath = '${tempDir.path}/resume_preserve.tmp';

      // 4 chunks with non-contiguous downloads:
      // Chunk 0: [0..249], downloaded 150
      // Chunk 1: [250..499], downloaded 0
      // Chunk 2: [500..749], downloaded 200
      // Chunk 3: [750..999], downloaded 50
      final savedState = TransferState(
        totalSize: 1000,
        threadCount: 4,
        status: DmxStateStatus.paused,
        chunks: [
          ChunkState(start: 0, end: 249, downloaded: 150),
          ChunkState(start: 250, end: 499, downloaded: 0),
          ChunkState(start: 500, end: 749, downloaded: 200),
          ChunkState(start: 750, end: 999, downloaded: 50),
        ],
      );
      await StateStore.save(tempFilePath, savedState, durable: true);
      await File(tempFilePath).writeAsBytes(List.filled(1000, 0), flush: true);

      // User resumes with threadCount = 2 (or changed concurrency)
      final cmd = DownloadCommand(
        taskId: 'preserve-chunk-test',
        url: 'https://example.com/file.bin',
        punyUrl: 'https://example.com/file.bin',
        localFilePath: '${tempDir.path}/file.bin',
        tempFilePath: tempFilePath,
        knownFileSize: 1000,
        threadCount: 2, // different from saved chunks (4)
        supportsResume: true,
      );

      final receivePort = ReceivePort();
      final job = HttpTransferJob(cmd, receivePort.sendPort);
      final reconciled = await job.loadAndReconcileState(Dio());
      receivePort.close();

      // Crucial: physical chunks must NOT be re-sliced into 2 chunks with flawed overlap sums!
      // All 4 physical segments must be retained with exact downloaded progress intact.
      expect(reconciled.chunks.length, equals(4));
      expect(reconciled.chunks[0].start, equals(0));
      expect(reconciled.chunks[0].end, equals(249));
      expect(reconciled.chunks[0].downloaded, equals(150));

      expect(reconciled.chunks[1].start, equals(250));
      expect(reconciled.chunks[1].end, equals(499));
      expect(reconciled.chunks[1].downloaded, equals(0));

      expect(reconciled.chunks[2].start, equals(500));
      expect(reconciled.chunks[2].end, equals(749));
      expect(reconciled.chunks[2].downloaded, equals(200));

      expect(reconciled.chunks[3].start, equals(750));
      expect(reconciled.chunks[3].end, equals(999));
      expect(reconciled.chunks[3].downloaded, equals(50));
    });

    test(
        'loadAndReconcileState re-plans chunks cleanly when downloadedBytes == 0',
        () async {
      final tempFilePath = '${tempDir.path}/zero_progress.tmp';

      final savedState = TransferState(
        totalSize: 2000000,
        threadCount: 2,
        status: DmxStateStatus.paused,
        chunks: [
          ChunkState(start: 0, end: 999999, downloaded: 0),
          ChunkState(start: 1000000, end: 1999999, downloaded: 0),
        ],
      );
      await StateStore.save(tempFilePath, savedState, durable: true);
      await File(tempFilePath).writeAsBytes(List.filled(2000000, 0), flush: true);

      // User resumes with threadCount = 4
      final cmd = DownloadCommand(
        taskId: 'zero-progress-test',
        url: 'https://example.com/file.bin',
        punyUrl: 'https://example.com/file.bin',
        localFilePath: '${tempDir.path}/file.bin',
        tempFilePath: tempFilePath,
        knownFileSize: 2000000,
        threadCount: 4,
        supportsResume: true,
      );

      final receivePort = ReceivePort();
      final job = HttpTransferJob(cmd, receivePort.sendPort);
      final reconciled = await job.loadAndReconcileState(Dio());
      receivePort.close();

      // Since 0 bytes were downloaded, safe to re-plan to 4 chunks
      expect(reconciled.chunks.length, equals(4));
      expect(reconciled.threadCount, equals(4));
      expect(reconciled.downloadedBytes, equals(0));
    });
  });

  group('HTTP Download Benchmark Audit - Connection Throttling', () {
    test('buildTransferDio configures HttpClient with maxConnectionsPerHost = 64',
        () {
      final dio = buildTransferDio(
        url: 'https://example.com/largefile.iso',
      );

      expect(dio.httpClientAdapter, isA<IOHttpClientAdapter>());
      final adapter = dio.httpClientAdapter as IOHttpClientAdapter;
      expect(adapter.createHttpClient, isNotNull);

      // Invoke factory to verify created HttpClient configuration
      final client = adapter.createHttpClient!();
      expect(client.maxConnectionsPerHost, equals(64));
      expect(client.idleTimeout, equals(const Duration(seconds: 30)));
    });
  });

  group('HTTP Download Benchmark Audit - Work-Stealing Split Guard', () {
    test('trySplitChunk correctly calculates non-overlapping sub-chunk ranges', () {
      // Chunk: start=0, end=9999999 (10MB), downloaded=2000000 (2MB)
      final parent = ChunkState(
        start: 0,
        end: 9999999,
        downloaded: 2000000,
      );

      final split = ChunkScheduler.trySplitChunk(parent);
      expect(split, isNotNull);
      final (first, second) = split!;

      // First chunk keeps downloaded bytes and ends at mid - 1
      expect(first.start, equals(0));
      expect(first.downloaded, equals(2000000));
      expect(first.end, lessThan(second.start));

      // Second chunk starts at mid and has 0 downloaded
      expect(second.start, equals(first.end + 1));
      expect(second.end, equals(9999999));
      expect(second.downloaded, equals(0));

      // Guard requirement: second chunk starts strictly ahead of parent downloaded position
      expect(second.start, greaterThan(parent.start + parent.downloaded));
    });
  });
}
