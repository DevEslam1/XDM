import 'dart:io';
import 'dart:typed_data';

import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pos_writer_concurrent_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('PositionalFileWriter handles high-concurrency multi-threaded writes without corruption', () async {
    final filePath = '${tempDir.path}/concurrent_test.bin';
    const chunkSize = 64 * 1024; // 64KB per thread
    const threadCount = 8;
    const totalSize = chunkSize * threadCount;

    final writer = await PositionalFileWriter.open(
      filePath,
      totalSize: totalSize,
      threadCount: threadCount,
      bufferSize: 16 * 1024,
    );

    // Prepare distinct data patterns per thread
    final threadPayloads = List.generate(threadCount, (threadIndex) {
      return Uint8List.fromList(
        List.generate(chunkSize, (byteIndex) => (threadIndex * 31 + byteIndex) % 256),
      );
    });

    // Write concurrently in slices
    final futures = <Future<void>>[];
    const sliceSize = 4096;
    for (var t = 0; t < threadCount; t++) {
      final threadIdx = t;
      final payload = threadPayloads[threadIdx];
      futures.add(Future(() async {
        final threadStart = threadIdx * chunkSize;
        for (var offset = 0; offset < chunkSize; offset += sliceSize) {
          final end = (offset + sliceSize > chunkSize) ? chunkSize : offset + sliceSize;
          final slice = payload.sublist(offset, end);
          await writer.write(threadIdx, threadStart + offset, slice);
        }
        await writer.flush(threadIdx);
      }));
    }

    await Future.wait(futures);
    await writer.close();

    final file = File(filePath);
    expect(await file.exists(), true);
    expect(await file.length(), totalSize);

    final writtenBytes = await file.readAsBytes();
    for (var t = 0; t < threadCount; t++) {
      final threadStart = t * chunkSize;
      final expected = threadPayloads[t];
      final actual = writtenBytes.sublist(threadStart, threadStart + chunkSize);
      expect(actual, equals(expected), reason: 'Thread $t data corrupted at chunk offset $threadStart');
    }
  });
}
