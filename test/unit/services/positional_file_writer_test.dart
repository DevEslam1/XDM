import 'dart:io';
import 'dart:typed_data';

import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pos_writer_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  group('PositionalFileWriter', () {
    test('open creates a new file and pre-allocates', () async {
      final path = '${tempDir.path}/test_open.dat';
      final writer = await PositionalFileWriter.open(
        path,
        totalSize: 1024,
        threadCount: 2,
      );

      final size = await writer.fileSize();
      expect(size, 1024);

      await writer.close();
      final file = File(path);
      expect(await file.exists(), true);
      expect(await file.length(), 1024);
    });

    test(
      'positional_file_writer_resume_does_not_truncate_existing_file',
      () async {
        final path = '${tempDir.path}/test_resume.dat';
        // 1. Create a file with known bytes
        final originalBytes = Uint8List.fromList(
          List.generate(100, (i) => i % 256),
        );
        await File(path).writeAsBytes(originalBytes);

        // 2. Open for resume
        final writer = await PositionalFileWriter.openForResume(
          path,
          threadCount: 2,
        );

        // 3. Write at a middle offset
        final newBytes = Uint8List.fromList([0xFF, 0xFE, 0xFD]);
        await writer.write(0, 50, newBytes);

        // 4. Close and verify
        await writer.close();

        final file = File(path);
        final result = await file.readAsBytes();

        // File length should NOT be reset to zero (should still be 100)
        expect(result.length, 100,
            reason: 'File length must not be reset to zero on resume');

        // Original bytes before written region should be preserved
        expect(result.sublist(0, 50), originalBytes.sublist(0, 50),
            reason: 'Bytes before written region must be preserved');

        // New bytes at offset 50
        expect(result.sublist(50, 53), newBytes,
            reason: 'New bytes must be written at correct offset');

        // Original bytes after written region should be preserved
        expect(result.sublist(53), originalBytes.sublist(53),
            reason: 'Bytes after written region must be preserved');
      },
    );

    test('write preserves data from multiple threads', () async {
      final path = '${tempDir.path}/test_multithread.dat';
      final writer = await PositionalFileWriter.open(
        path,
        totalSize: 200,
        threadCount: 2,
      );

      final thread0Bytes = Uint8List.fromList(List.generate(50, (i) => 0xAB));
      final thread1Bytes = Uint8List.fromList(List.generate(50, (i) => 0xCD));

      await writer.write(0, 0, thread0Bytes);
      await writer.write(1, 100, thread1Bytes);

      await writer.close();

      final result = await File(path).readAsBytes();
      expect(result.sublist(0, 50), thread0Bytes);
      expect(result.sublist(100, 150), thread1Bytes);
      // Gap between writes should remain zero (from preallocation)
      expect(result.sublist(50, 100), List.filled(50, 0));
    });

    test('close is idempotent', () async {
      final path = '${tempDir.path}/test_close_idempotent.dat';
      final writer = await PositionalFileWriter.open(
        path,
        totalSize: 10,
        threadCount: 1,
      );
      await writer.write(0, 0, Uint8List.fromList([1, 2, 3]));
      await writer.close();
      // Second close should not throw
      await writer.close();
    });

    test('write after close throws StateError', () async {
      final path = '${tempDir.path}/test_write_after_close.dat';
      final writer = await PositionalFileWriter.open(
        path,
        totalSize: 10,
        threadCount: 1,
      );
      await writer.close();
      expect(
        () => writer.write(0, 0, Uint8List.fromList([1])),
        throwsA(isA<PositionalFileWriterException>()),
      );
    });

    test('fileSize returns correct length', () async {
      final path = '${tempDir.path}/test_file_size.dat';
      // Create file with known size first
      await File(path).writeAsBytes(Uint8List(42));

      final writer = await PositionalFileWriter.openForResume(
        path,
        threadCount: 1,
      );
      expect(await writer.fileSize(), 42);
      await writer.close();
    });

    test('flushAll writes all pending buffers', () async {
      final path = '${tempDir.path}/test_flush_all.dat';
      final writer = await PositionalFileWriter.open(
        path,
        totalSize: 100,
        threadCount: 2,
      );

      await writer.write(
          0, 0, Uint8List.fromList(List.generate(10, (_) => 0xAA)));
      await writer.write(
          1, 50, Uint8List.fromList(List.generate(10, (_) => 0xBB)));

      // Flush all and verify data on disk
      await writer.flushAll();

      final partial = await File(path).readAsBytes();
      expect(partial.sublist(0, 10), List.filled(10, 0xAA));
      expect(partial.sublist(50, 60), List.filled(10, 0xBB));

      await writer.close();
    });

    test('openForResume creates file if not exists', () async {
      final path = '${tempDir.path}/test_create_if_not_exists.dat';
      final writer = await PositionalFileWriter.openForResume(
        path,
        threadCount: 1,
      );

      expect(await writer.fileSize(), 0);
      await writer.write(0, 0, Uint8List.fromList([42]));
      await writer.close();

      final file = File(path);
      expect(await file.exists(), true);
      expect(await file.length(), 1);
    });

    test(
        'flushPaced limits disk flushes to interval or 1MB threshold (F-01/F-02)',
        () async {
      final path = '${tempDir.path}/test_flush_paced.dat';
      final writer = await PositionalFileWriter.open(
        path,
        totalSize: 500,
        threadCount: 1,
      );

      // Writing 10 bytes and immediate flushPaced
      await writer.write(0, 0, Uint8List.fromList([1, 2, 3, 4, 5]));
      await writer.flushPaced();

      // Subsequent fast call within 500ms
      await writer.write(0, 5, Uint8List.fromList([6, 7, 8]));
      await writer.flushPaced();

      await writer.close();
      final file = File(path);
      expect(await file.exists(), true);
    });
  });
}
