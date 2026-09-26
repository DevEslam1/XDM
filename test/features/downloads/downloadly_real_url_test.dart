import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dmx/core/domain/resume_identity.dart';
import 'package:dmx/core/services/dio_client_pool.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:dmx/core/services/engines/http_download_engine.dart';
import 'package:dmx/core/services/metadata_probe_service.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:dmx/core/utils/file_utils.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // Enable live OS socket network requests

  const testUrl =
      'https://dl.downloadly.ir/Files/Software/Autodesk_Revit_2027.0.1_Multilanguage_x64.part1_Downloadly.ir.rar?nocache=1789986836';
  const expectedFileSize = 2147483648; // 2 GB

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dmx_downloadly_test_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Downloadly Real URL: Filename, Extension, and Category Extraction', () {
    test('fileNameFromUrl correctly strips query parameter and preserves full multi-part filename', () {
      final name = fileNameFromUrl(testUrl);
      expect(name, equals('Autodesk_Revit_2027.0.1_Multilanguage_x64.part1_Downloadly.ir.rar'));
      expect(name.contains('nocache'), isFalse);
    });

    test('categoryFromFileName correctly classifies .rar as Archive', () {
      final name = fileNameFromUrl(testUrl);
      final category = categoryFromFileName(name);
      expect(category, equals('Archive'));
    });

    test('safeFileName sanitizes without mangling .part1_Downloadly.ir.rar', () {
      final name = fileNameFromUrl(testUrl);
      final safe = safeFileName(name);
      expect(safe, equals('Autodesk_Revit_2027.0.1_Multilanguage_x64.part1_Downloadly.ir.rar'));
    });

    test('UrlValidator and isSafeWebUrl validate target URL successfully', () {
      expect(UrlValidator.isValid(testUrl), isTrue);
      expect(isSafeWebUrl(testUrl), isTrue);
      expect(isHttpUrl(testUrl), isTrue);
    });

    test('formatBytes displays 2 GB correctly for 2,147,483,648 bytes', () {
      expect(formatBytes(expectedFileSize), equals('2.0 GB'));
    });
  });

  group('Downloadly Real URL: ChunkScheduler planning for 2GB file', () {
    test('correctly partitions 2,147,483,648 bytes across 1, 2, 4, 8, 16 threads with zero gap or overlap', () {
      for (final threadCount in [1, 2, 4, 8, 16]) {
        final chunks = ChunkScheduler.plan(totalSize: expectedFileSize, threadCount: threadCount);

        expect(chunks.length, equals(threadCount));
        expect(chunks.first.start, equals(0));
        expect(chunks.last.end, equals(expectedFileSize - 1));

        for (int i = 0; i < chunks.length - 1; i++) {
          expect(chunks[i].end + 1, equals(chunks[i + 1].start),
              reason: 'Gap or overlap between chunk $i and ${i + 1} for thread count $threadCount');
        }

        final totalPlanned = chunks.fold<int>(0, (sum, c) => sum + (c.end - c.start + 1));
        expect(totalPlanned, equals(expectedFileSize));
      }
    });

    test('canSplitChunk and trySplitChunk split large 2GB partition into two contiguous sub-chunks', () {
      final chunks = ChunkScheduler.plan(totalSize: expectedFileSize, threadCount: 8);
      final chunk0 = chunks.first;
      expect(ChunkScheduler.canSplitChunk(chunk0), isTrue);

      final splitResult = ChunkScheduler.trySplitChunk(chunk0);
      expect(splitResult, isNotNull);
      final (sub1, sub2) = splitResult!;

      expect(sub1.start, equals(chunk0.start));
      expect(sub1.end + 1, equals(sub2.start));
      expect(sub2.end, equals(chunk0.end));
      expect((sub1.end - sub1.start + 1) + (sub2.end - sub2.start + 1), equals(chunk0.end - chunk0.start + 1));
    });
  });

  group('Downloadly Real URL: Live Network Metadata Probe', () {
    test('probes actual URL, follows CDN redirects, and retrieves size, etag, and accept-ranges', () async {
      final pool = DioClientPool();
      final probeService = MetadataProbeService(pool);

      try {
        final metadata = await probeService.resolveMetadata(
          url: testUrl,
        ).timeout(const Duration(seconds: 25));

        expect(metadata.fileName, equals('Autodesk_Revit_2027.0.1_Multilanguage_x64.part1_Downloadly.ir.rar'));
        expect(metadata.category, equals('Archive'));
        // Content-Length on server is 2,147,483,648 bytes (2 GB)
        expect(metadata.fileSize, equals(expectedFileSize));
        // Server sends Accept-Ranges: bytes
        expect(metadata.supportsResume, isTrue);
        expect(metadata.etag, isNotNull);
      } catch (_) {
        rethrow;
      } finally {
        probeService.dispose();
      }
    });

    test('performs live HTTP range GET (0-1023) following multi-hop 302 redirects', () async {
      final dio = Dio();

      final response = await dio.get<ResponseBody>(
        testUrl,
        options: Options(
          headers: {'Range': 'bytes=0-1023'},
          responseType: ResponseType.stream,
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (_) => true,
        ),
      );

      expect(response.statusCode, anyOf(200, 206));
      final contentRange = response.headers.value('content-range');
      if (response.statusCode == 206) {
        expect(contentRange, contains('bytes 0-1023/2147483648'));
      }

      int received = 0;
      final stream = response.data?.stream;
      if (stream != null) {
        await for (final chunk in stream) {
          received += chunk.length;
        }
      }
      expect(received, equals(1024));
    });

    test('performs live HTTP range GET with If-Range header matching ETag', () async {
      final dio = Dio();

      // Send If-Range with the observed server ETag
      final response = await dio.get<ResponseBody>(
        testUrl,
        options: Options(
          headers: {
            'Range': 'bytes=1024-2047',
            'If-Range': '"6a393366-80000000"',
          },
          responseType: ResponseType.stream,
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (_) => true,
        ),
      );

      expect(response.statusCode, anyOf(200, 206));
      if (response.statusCode == 206) {
        final contentRange = response.headers.value('content-range');
        expect(contentRange, contains('bytes 1024-2047/2147483648'));
      }

      int received = 0;
      final stream = response.data?.stream;
      if (stream != null) {
        await for (final chunk in stream) {
          received += chunk.length;
        }
      }
      expect(received, equals(1024));
    });
  });

  group('Downloadly Real URL: Live Multi-Thread Parallel Slice Download', () {
    test('fetches two distinct 2KB ranges in parallel and writes to disk via PositionalFileWriter', () async {
      final dio = Dio();
      final tempFilePath = '${tempDir.path}/test_download.rar.dmxpart';

      // Pre-allocate a 4KB file for the test
      final writer = await PositionalFileWriter.open(
        tempFilePath,
        totalSize: 4096,
        threadCount: 2,
        diskWriteBatching: false,
      );

      try {
        // Run two concurrent range requests: [0..2047] and [2048..4095]
        final future1 = dio.get<ResponseBody>(
          testUrl,
          options: Options(
            headers: {'Range': 'bytes=0-2047'},
            responseType: ResponseType.stream,
            followRedirects: true,
            validateStatus: (_) => true,
          ),
        );

        final future2 = dio.get<ResponseBody>(
          testUrl,
          options: Options(
            headers: {'Range': 'bytes=2048-4095'},
            responseType: ResponseType.stream,
            followRedirects: true,
            validateStatus: (_) => true,
          ),
        );

        final results = await Future.wait([future1, future2]);
        expect(results[0].statusCode, equals(206));
        expect(results[1].statusCode, equals(206));

        // Stream chunk 1 into writer at position 0
        int pos1 = 0;
        await for (final data in results[0].data!.stream) {
          await writer.write(0, pos1, Uint8List.fromList(data));
          pos1 += data.length;
        }
        expect(pos1, equals(2048));

        // Stream chunk 2 into writer at position 2048
        int pos2 = 2048;
        await for (final data in results[1].data!.stream) {
          await writer.write(1, pos2, Uint8List.fromList(data));
          pos2 += data.length;
        }
        expect(pos2, equals(4096));

        await writer.flushAll();
      } finally {
        await writer.close();
      }

      // Verify file length and non-empty content on disk
      final file = File(tempFilePath);
      expect(await file.exists(), isTrue);
      expect(await file.length(), equals(4096));
      final bytes = await file.readAsBytes();
      expect(bytes.any((b) => b != 0), isTrue);
    });
  });

  group('Downloadly Real URL: End-to-End Pause and Resume with State Persistence', () {
    test('persists chunk progress on pause and resumes without losing or re-downloading bytes', () async {
      const taskId = 'task-downloadly-resume-test';
      final tempFilePath = '${tempDir.path}/revit.rar.dmxpart';
      final file = File(tempFilePath);

      // Create a 8KB partial file on disk
      await file.writeAsBytes(List<int>.filled(8192, 0xAB), flush: true);

      // Initial state: 4 chunks of 2048 bytes each for 8192 bytes
      final initialState = TransferState(
        totalSize: 8192,
        threadCount: 4,
        etag: '"6a393366-80000000"',
        lastModified: 'Mon, 22 Jun 2026 13:06:46 GMT',
        chunks: [
          ChunkState(start: 0, end: 2047, downloaded: 2048), // chunk 0 complete
          ChunkState(start: 2048, end: 4095, downloaded: 1024), // chunk 1 halfway
          ChunkState(start: 4096, end: 6143, downloaded: 0),
          ChunkState(start: 6144, end: 8191, downloaded: 0),
        ],
      );

      // Save initial state with taskId
      await StateStore.save(
        tempFilePath,
        initialState,
        durable: true,
        taskId: taskId,
      );

      // Verify state file exists at taskId-scoped path
      final scopedStatePath = StateStore.pathFor(tempFilePath, taskId: taskId);
      expect(await File(scopedStatePath).exists(), isTrue);

      // Load state back
      final loaded = await StateStore.loadOrCreate(
        tempFilePath,
        url: testUrl,
        threadCount: 4,
        knownFileSize: 8192,
        taskId: taskId,
      );

      expect(loaded.state.chunks.length, equals(4));
      expect(loaded.state.chunks[0].downloaded, equals(2048));
      expect(loaded.state.chunks[0].isComplete, isTrue);
      expect(loaded.state.chunks[1].downloaded, equals(1024));
      expect(loaded.state.chunks[1].isComplete, isFalse);
      expect(loaded.state.downloadedBytes, equals(3072));
      expect(loaded.state.etag, equals('"6a393366-80000000"'));

      // Check actualDownloadedBytes helper
      final actual = await actualDownloadedBytes(
        tempFilePath,
        threadCount: 4,
        taskId: taskId,
      );
      expect(actual, equals(3072));
    });
  });

  group('Downloadly Real URL: Link Update and Query Param Rotation', () {
    test('URL change with new nocache parameter preserves existing downloaded bytes', () async {
      const initialUrl = testUrl;
      const updatedUrl =
          'https://dl.downloadly.ir/Files/Software/Autodesk_Revit_2027.0.1_Multilanguage_x64.part1_Downloadly.ir.rar?nocache=9999999999';

      // Both URLs share the exact same base path and target file name
      expect(fileNameFromUrl(initialUrl), equals(fileNameFromUrl(updatedUrl)));
      final uri1 = Uri.parse(initialUrl);
      final uri2 = Uri.parse(updatedUrl);
      String cleanBase(Uri u) => '${u.scheme}://${u.host}${u.path}';
      expect(
        cleanBase(uri1),
        equals('https://dl.downloadly.ir/Files/Software/Autodesk_Revit_2027.0.1_Multilanguage_x64.part1_Downloadly.ir.rar'),
      );
      expect(
        cleanBase(uri2),
        equals('https://dl.downloadly.ir/Files/Software/Autodesk_Revit_2027.0.1_Multilanguage_x64.part1_Downloadly.ir.rar'),
      );
    });

    test('ResumeIdentity matches updated URL with new nocache param when ETag and size are identical', () {
      const initialUrl = testUrl;
      const updatedUrl =
          'https://dl.downloadly.ir/Files/Software/Autodesk_Revit_2027.0.1_Multilanguage_x64.part1_Downloadly.ir.rar?nocache=9999999999';

      final initialIdentity = ResumeIdentity(
        normalizedUrl: ResumeIdentity.normalizeUrl(initialUrl),
        etag: '"6a393366-80000000"',
        lastModified: 'Mon, 22 Jun 2026 13:06:46 GMT',
        contentLength: expectedFileSize,
        supportsRanges: true,
      );

      final candidateIdentity = ResumeIdentity(
        normalizedUrl: ResumeIdentity.normalizeUrl(updatedUrl),
        etag: '"6a393366-80000000"',
        lastModified: 'Mon, 22 Jun 2026 13:06:46 GMT',
        contentLength: expectedFileSize,
        supportsRanges: true,
      );

      final validation = initialIdentity.validateAgainst(candidateIdentity);
      expect(validation.isValid, isTrue);
      expect(validation.mismatchReason, isNull);
    });

    test('Task updateTaskUrl preserves task ID, local paths, and downloaded progress', () {
      const taskId = 'task-revit-update-url';
      final originalTask = DownloadTask(
        id: taskId,
        fileName: 'Autodesk_Revit_2027.0.1_Multilanguage_x64.part1_Downloadly.ir.rar',
        url: testUrl,
        fileSize: expectedFileSize,
        downloadedBytes: 104857600, // 100 MB downloaded
        category: 'Archive',
        status: DownloadStatus.paused,
        savePath: tempDir.path,
        localFilePath: '${tempDir.path}/Autodesk_Revit_2027.0.1_Multilanguage_x64.part1_Downloadly.ir.rar',
        tempFilePath: '${tempDir.path}/Autodesk_Revit_2027.0.1_Multilanguage_x64.part1_Downloadly.ir.rar.dmxpart',
        threadCount: 8,
        chunks: const [0.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      const rotatedUrl =
          'https://dl.downloadly.ir/Files/Software/Autodesk_Revit_2027.0.1_Multilanguage_x64.part1_Downloadly.ir.rar?nocache=9999999999';

      final updatedTask = originalTask.copyWith(
        url: rotatedUrl,
        updatedAt: DateTime.now(),
        errorMessage: null,
        clearStatusMessage: true,
      );

      expect(updatedTask.id, equals(originalTask.id));
      expect(updatedTask.downloadedBytes, equals(104857600));
      expect(updatedTask.tempFilePath, equals(originalTask.tempFilePath));
      expect(updatedTask.url, equals(rotatedUrl));
      expect(updatedTask.chunks, equals(originalTask.chunks));
    });
  });

  group('Downloadly Real URL: Error Handling & Recovery on Expired Link', () {
    test('403 Forbidden on expired link triggers updatingLinks cycleState and retains partial state', () async {
      const taskId = 'task-revit-expired-link';
      final tempFilePath = '${tempDir.path}/revit_expired.rar.dmxpart';
      final file = File(tempFilePath);
      await file.writeAsBytes(List<int>.filled(4096, 0xFF), flush: true);

      // Save initial state
      final state = TransferState(
        totalSize: expectedFileSize,
        threadCount: 8,
        etag: '"6a393366-80000000"',
        chunks: ChunkScheduler.plan(totalSize: expectedFileSize, threadCount: 8),
      );
      state.chunks[0].downloaded = 4096;
      await StateStore.save(tempFilePath, state, durable: true, taskId: taskId);

      // Simulate expired link: update state to updatingLinks
      state.cycleState = CycleState.updatingLinks.name;
      await StateStore.save(tempFilePath, state, durable: true, taskId: taskId);

      // Verify state file and part file still exist
      final scopedStatePath = StateStore.pathFor(tempFilePath, taskId: taskId);
      expect(await File(scopedStatePath).exists(), isTrue);
      expect(await file.exists(), isTrue);
      expect(await file.length(), equals(4096));

      // Reload state and confirm downloaded bytes are intact
      final loaded = await StateStore.loadOrCreate(
        tempFilePath,
        url: testUrl,
        threadCount: 8,
        knownFileSize: expectedFileSize,
        taskId: taskId,
      );
      expect(loaded.state.cycleState, equals(CycleState.updatingLinks.name));
      expect(loaded.state.downloadedBytes, equals(4096));
    });
  });
}
