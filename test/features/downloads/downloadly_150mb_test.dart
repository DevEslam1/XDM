import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:dmx/core/services/engines/http_download_engine.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:dmx/core/utils/file_utils.dart';
import 'package:flutter_test/flutter_test.dart';

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // Enable live OS socket network requests

  const testUrl =
      'https://dl.downloadly.ir/Files/Software/Autodesk_Revit_2027.0.1_Multilanguage_x64.part1_Downloadly.ir.rar?nocache=1789986836';
  const total2GbSize = 2147483648; // 2 GB (exact Content-Length)
  const total150MbSize = 150 * 1024 * 1024; // 157,286,400 bytes (150 MB)
  const threadCount = 8;
  const cycleCount = 6; // 6 Pause / Resume cycles requested by user

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dmx_150mb_6cycle_test_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Downloadly Real URL: 6 Live Pause / Resume Cycles Against Server', () {
    test(
      'executes 6 live pause/resume cycles on real downloadly CDN, verifying hash integrity at every step',
      () async {
        final dio = Dio();
        const taskId = 'live-downloadly-6-cycles';
        final tempFilePath = '${tempDir.path}/live_6cycle_revit.rar.dmxpart';

        final plannedChunks = ChunkScheduler.plan(totalSize: total2GbSize, threadCount: threadCount);
        expect(plannedChunks.length, equals(threadCount));

        const activeThreads = 4;
        const bytesPerCyclePerThread = 128 * 1024; // 128 KB per thread per cycle

        // Pre-allocate sparse 2GB file
        final initialWriter = await PositionalFileWriter.open(
          tempFilePath,
          totalSize: total2GbSize,
          threadCount: threadCount,
          diskWriteBatching: false,
        );
        await initialWriter.close();

        var currentState = TransferState(
          totalSize: total2GbSize,
          threadCount: threadCount,
          etag: '"6a393366-80000000"',
          lastModified: 'Mon, 22 Jun 2026 13:06:46 GMT',
          chunks: plannedChunks,
        );
        await StateStore.save(tempFilePath, currentState, durable: true, taskId: taskId);

        // Track accumulated per-chunk digests across all 6 cycles
        final expectedChunkData = List.generate(activeThreads, (_) => <int>[]);

        for (int cycle = 1; cycle <= cycleCount; cycle++) {
          // 1. Open writer for this cycle
          final writer = await PositionalFileWriter.openForResume(
            tempFilePath,
            threadCount: threadCount,
            totalSize: total2GbSize,
            diskWriteBatching: false,
          );

          // 2. Download slice for this cycle across all active threads
          final cycleFutures = <Future<void>>[];

          for (int t = 0; t < activeThreads; t++) {
            final chunkIndex = t;
            final chunk = currentState.chunks[chunkIndex];
            final startOffset = chunk.start + chunk.downloaded;
            final endOffset = startOffset + bytesPerCyclePerThread - 1;

            cycleFutures.add(() async {
              Response<ResponseBody>? response;
              for (int attempt = 1; attempt <= 4; attempt++) {
                try {
                  response = await dio.get<ResponseBody>(
                    testUrl,
                    options: Options(
                      headers: {
                        'Range': 'bytes=$startOffset-$endOffset',
                        'If-Range': '"6a393366-80000000"',
                      },
                      responseType: ResponseType.stream,
                      followRedirects: true,
                      validateStatus: (_) => true,
                    ),
                  );
                  if (response.statusCode == 206) break;
                } catch (e) {
                  if (attempt == 4) rethrow;
                  await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
                }
              }

              expect(response, isNotNull);
              expect(response!.statusCode, equals(206));
              int writePos = startOffset;
              final buffer = BytesBuilder(copy: false);

              await for (final data in response.data!.stream) {
                await writer.write(chunkIndex, writePos, Uint8List.fromList(data));
                buffer.add(data);
                writePos += data.length;
              }

              final received = buffer.takeBytes();
              expect(received.length, equals(bytesPerCyclePerThread));
              expectedChunkData[chunkIndex].addAll(received);
              chunk.downloaded += received.length;
            }());
          }

          await Future.wait(cycleFutures);
          await writer.flushAll();

          // 3. PAUSE: Persist state and close file handle
          currentState.status = DmxStateStatus.paused;
          await StateStore.save(tempFilePath, currentState, durable: true, taskId: taskId);
          await writer.close();
          await Future<void>.delayed(const Duration(milliseconds: 100));

          // 4. CHECK DATA LOSS AFTER CYCLE: Verify on-disk data integrity up to this cycle
          final raf = await File(tempFilePath).open(mode: FileMode.read);
          try {
            for (int t = 0; t < activeThreads; t++) {
              final expectedBytes = expectedChunkData[t];
              await raf.setPosition(plannedChunks[t].start);
              final onDisk = await raf.read(expectedBytes.length);
              expect(sha256.convert(onDisk), equals(sha256.convert(expectedBytes)),
                  reason: 'Data loss detected at Cycle $cycle for thread $t!');
            }
          } finally {
            await raf.close();
          }

          // 5. RESUME: Verify state store can load without losing bytes
          final reloaded = await StateStore.loadOrCreate(
            tempFilePath,
            url: testUrl,
            threadCount: threadCount,
            knownFileSize: total2GbSize,
            taskId: taskId,
          );
          final expectedTotalDownloaded = cycle * activeThreads * bytesPerCyclePerThread;
          expect(reloaded.state.downloadedBytes, equals(expectedTotalDownloaded));
          currentState = reloaded.state;
        }

        // Final total check
        final finalDownloaded = await actualDownloadedBytes(
          tempFilePath,
          threadCount: threadCount,
          taskId: taskId,
        );
        expect(finalDownloaded, equals(cycleCount * activeThreads * bytesPerCyclePerThread));
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );
  });

  group('Downloadly 150MB / 2GB: 6 Pause / Resume Cycles Data Lossing Stress Test', () {
    test(
      'executes exactly 6 pause/resume cycles covering 150MB across all 8 threads of 2GB file, verifying zero data loss at every cycle',
      () async {
        const taskId = 'task-revit-150mb-6-cycles';
        final tempFilePath = '${tempDir.path}/revit_150mb_6cycles.rar.dmxpart';

        // Plan 8 chunks for 2GB file (268,435,456 bytes per chunk)
        final chunks = ChunkScheduler.plan(totalSize: total2GbSize, threadCount: threadCount);
        expect(chunks.length, equals(8));

        // Total 150 MB / 6 cycles = 25 MB per cycle (26,214,400 bytes)
        // 25 MB / 8 threads = 3,276,800 bytes (~3.125 MB) per thread per cycle
        const totalBytesPerThread = total150MbSize ~/ threadCount; // 19,660,800 bytes (18.75 MB)
        const bytesPerCyclePerThread = totalBytesPerThread ~/ cycleCount; // 3,276,800 bytes (3.125 MB)
        const bytesPerCycleTotal = bytesPerCyclePerThread * threadCount; // 26,214,400 bytes (25.0 MB)

        // Initialize 2GB sparse file
        final initialWriter = await PositionalFileWriter.open(
          tempFilePath,
          totalSize: total2GbSize,
          threadCount: threadCount,
          diskWriteBatching: false,
        );
        await initialWriter.close();

        var state = TransferState(
          totalSize: total2GbSize,
          threadCount: threadCount,
          etag: '"6a393366-80000000"',
          lastModified: 'Mon, 22 Jun 2026 13:06:46 GMT',
          chunks: chunks,
        );
        await StateStore.save(tempFilePath, state, durable: true, taskId: taskId);

        // Store cumulative digests for each chunk after each cycle:
        // cumulativeChunkDigests[cycle][chunkIndex] = Digest
        final cumulativeChunkDigests = <int, Map<int, Digest>>{};
        const bufferSize = 64 * 1024; // 64 KB write chunks

        // ═══════════════════════════════════════════════════════════════════
        // EXECUTE 6 CONSECUTIVE PAUSE / RESUME CYCLES
        // ═══════════════════════════════════════════════════════════════════
        for (int cycle = 1; cycle <= cycleCount; cycle++) {
          // -----------------------------------------------------------------
          // RESUME: Load state from disk and open writer in resume mode
          // -----------------------------------------------------------------
          final loadedState = await StateStore.loadOrCreate(
            tempFilePath,
            url: testUrl,
            threadCount: threadCount,
            knownFileSize: total2GbSize,
            taskId: taskId,
          );

          // Verify chunks were not reset or lost on resume
          final expectedPriorBytes = (cycle - 1) * bytesPerCycleTotal;
          expect(loadedState.state.downloadedBytes, equals(expectedPriorBytes),
              reason: 'Downloaded bytes were wiped or lost when loading state for cycle $cycle!');

          final writer = await PositionalFileWriter.openForResume(
            tempFilePath,
            threadCount: threadCount,
            totalSize: total2GbSize,
            diskWriteBatching: false,
          );

          // -----------------------------------------------------------------
          // DOWNLOAD STAGE: Write 25 MB (3.125 MB per thread) for this cycle
          // -----------------------------------------------------------------
          for (int t = 0; t < threadCount; t++) {
            final chunk = loadedState.state.chunks[t];
            final writeStartOffset = chunk.start + chunk.downloaded;
            var writtenInThisCycle = 0;

            // Pattern distinct to each (cycle, chunk) to detect any cross-cycle or cross-chunk corruption
            final patternByte = ((cycle * 0x20) + t) & 0xFF;
            final patternBuffer = Uint8List(bufferSize)..fillRange(0, bufferSize, patternByte);

            while (writtenInThisCycle < bytesPerCyclePerThread) {
              final toWrite = (bytesPerCyclePerThread - writtenInThisCycle).clamp(0, bufferSize);
              final slice = toWrite == bufferSize ? patternBuffer : Uint8List.sublistView(patternBuffer, 0, toWrite);

              await writer.write(t, writeStartOffset + writtenInThisCycle, slice);
              writtenInThisCycle += toWrite;
            }

            chunk.downloaded += writtenInThisCycle;
          }

          await writer.flushAll();

          // -----------------------------------------------------------------
          // PAUSE: Set status to paused, save state, and close writer
          // -----------------------------------------------------------------
          loadedState.state.status = DmxStateStatus.paused;
          await StateStore.save(tempFilePath, loadedState.state, durable: true, taskId: taskId);
          await writer.close();

          // -----------------------------------------------------------------
          // DATA LOSS CHECK: Verify entire physical file contents on disk
          // -----------------------------------------------------------------
          final currentTotalDownloaded = cycle * bytesPerCycleTotal;
          final downloadedOnDisk = await actualDownloadedBytes(
            tempFilePath,
            threadCount: threadCount,
            taskId: taskId,
          );
          expect(downloadedOnDisk, equals(currentTotalDownloaded));

          // Verify cryptographic SHA-256 for all bytes downloaded up to this cycle
          final raf = await File(tempFilePath).open(mode: FileMode.read);
          final cycleDigests = <int, Digest>{};

          try {
            for (int t = 0; t < threadCount; t++) {
              final chunkStart = chunks[t].start;

              await raf.setPosition(chunkStart);
              final acc = _DigestSink();
              final shaStream = sha256.startChunkedConversion(acc);

              // Read back all cycles up to current cycle for this chunk
              for (int c = 1; c <= cycle; c++) {
                final expectedPatternByte = ((c * 0x20) + t) & 0xFF;
                var cycleBytesRead = 0;

                while (cycleBytesRead < bytesPerCyclePerThread) {
                  final toRead = (bytesPerCyclePerThread - cycleBytesRead).clamp(0, bufferSize);
                  final bytes = await raf.read(toRead);

                  // Byte-level validation: confirm every single byte matches the exact expected pattern
                  for (int b = 0; b < bytes.length; b++) {
                    if (bytes[b] != expectedPatternByte) {
                      fail('Data Loss Detected! Byte corruption at cycle $c, thread $t, byte offset ${cycleBytesRead + b}: '
                          'expected 0x${expectedPatternByte.toRadixString(16)}, got 0x${bytes[b].toRadixString(16)}');
                    }
                  }

                  shaStream.add(bytes);
                  cycleBytesRead += bytes.length;
                }
              }

              shaStream.close();
              cycleDigests[t] = acc.value!;

              // If previous cycle digest exists, ensure current digest incorporates new data without losing prior
              if (cycle > 1) {
                expect(cycleDigests[t], isNot(equals(cumulativeChunkDigests[cycle - 1]![t])),
                    reason: 'Digest did not advance after cycle $cycle for thread $t');
              }
            }
          } finally {
            await raf.close();
          }

          cumulativeChunkDigests[cycle] = cycleDigests;
          state = loadedState.state;
        }

        // ═══════════════════════════════════════════════════════════════════
        // FINAL VERIFICATION: 150 MB / 2 GB COMPREHENSIVE INTEGRITY
        // ═══════════════════════════════════════════════════════════════════
        // 1. Confirm total downloaded equals 150 MB (157,286,400 bytes)
        final finalTotalOnDisk = await actualDownloadedBytes(
          tempFilePath,
          threadCount: threadCount,
          taskId: taskId,
        );
        expect(finalTotalOnDisk, equals(total150MbSize));
        expect(formatBytes(finalTotalOnDisk), equals('150.0 MB'));

        // 2. Confirm progress fraction matches ~150MB / 2048MB = 7.32%
        final progressFraction = finalTotalOnDisk / total2GbSize;
        expect(progressFraction, closeTo(150.0 / 2048.0, 0.001));

        // 3. Confirm all 8 chunks have exact expected downloaded count (18.75 MB each)
        for (int t = 0; t < threadCount; t++) {
          expect(state.chunks[t].downloaded, equals(totalBytesPerThread));
          expect(state.chunks[t].isComplete, isFalse); // Each chunk is 256MB, so 18.75MB is ~7.3% complete
        }

        // 4. Test link update / URL rotation after 6 pause/resumes:
        // Update URL to new nocache param and verify no data is wiped or re-downloaded
        const updatedUrl =
            'https://dl.downloadly.ir/Files/Software/Autodesk_Revit_2027.0.1_Multilanguage_x64.part1_Downloadly.ir.rar?nocache=9999999999';
        final stateAfterUrlUpdate = await StateStore.loadOrCreate(
          tempFilePath,
          url: updatedUrl,
          threadCount: threadCount,
          knownFileSize: total2GbSize,
          taskId: taskId,
        );
        expect(stateAfterUrlUpdate.state.downloadedBytes, equals(total150MbSize));
        for (int t = 0; t < threadCount; t++) {
          expect(stateAfterUrlUpdate.state.chunks[t].downloaded, equals(totalBytesPerThread));
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );
  });
}
