import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/positional_file_writer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PositionalFileWriter', () {
    test('openForResume preserves existing data and allows seeking', () async {
      const int fileSize = 1024 * 1024; // 1 MB
      const int writeOffset = 512 * 1024; // 512 KB
      const int writeSize = 512 * 1024; // 512 KB to write

      final tempDir = Directory.systemTemp;
      final filePath =
          '${tempDir.path}/resume_test_${DateTime.now().millisecondsSinceEpoch}.bin';

      // 1. Write 1 MB of known bytes to a temp file.
      final originalFile = File(filePath);
      final originalData = Uint8List(fileSize);
      for (int i = 0; i < fileSize; i++) {
        originalData[i] = 0xAB;
      }
      await originalFile.writeAsBytes(originalData, flush: true);
      expect(await originalFile.length(), fileSize);

      // 2. Call openForResume() on that file.
      final writer = await PositionalFileWriter.openForResume(
        filePath,
        threadCount: 2,
      );

      // 3. Write 512 KB at offset 512 KB via write().
      final newData = Uint8List(writeSize);
      for (int i = 0; i < writeSize; i++) {
        newData[i] = 0xCD;
      }
      await writer.write(0, writeOffset, newData);
      await writer.flushAll();
      await writer.close();

      // 4. Assert bytes 0-512 KB are unchanged (not zeroed).
      final fileAfter = File(filePath);
      final readBack = await fileAfter.readAsBytes();
      expect(readBack.length, fileSize);

      for (int i = 0; i < writeOffset; i++) {
        expect(readBack[i], 0xAB,
            reason:
                'Byte at position $i should be unchanged 0xAB, got 0x${readBack[i].toRadixString(16)}');
      }

      // 5. Assert bytes 512 KB-1 MB contain the new data.
      for (int i = 0; i < writeSize; i++) {
        expect(readBack[writeOffset + i], 0xCD,
            reason:
                'Byte at position ${writeOffset + i} should be new 0xCD, got 0x${readBack[writeOffset + i].toRadixString(16)}');
      }

      // 6. Assert file length is still 1 MB.
      expect(await fileAfter.length(), fileSize);
      await fileAfter.delete();
    });

    test('openForResume creates new file when it does not exist', () async {
      final tempDir = Directory.systemTemp;
      final filePath =
          '${tempDir.path}/new_file_${DateTime.now().millisecondsSinceEpoch}.bin';

      final writer = await PositionalFileWriter.openForResume(
        filePath,
        threadCount: 2,
      );

      final data = Uint8List(4096);
      for (int i = 0; i < 4096; i++) {
        data[i] = 0x42;
      }
      await writer.write(0, 0, data);
      await writer.flushAll();

      final file = File(filePath);
      expect(await file.exists(), true);
      expect(await file.length(), 4096);

      final readBack = await file.readAsBytes();
      for (int i = 0; i < 4096; i++) {
        expect(readBack[i], 0x42);
      }

      await writer.close();
      await file.delete();
    });

    test('close prevents further writes', () async {
      final tempDir = Directory.systemTemp;
      final filePath =
          '${tempDir.path}/close_test_${DateTime.now().millisecondsSinceEpoch}.bin';

      final writer = await PositionalFileWriter.openForResume(
        filePath,
        threadCount: 1,
      );
      await writer.close();

      expect(
        () => writer.write(0, 0, Uint8List(1)),
        throwsA(isA<StateError>()),
      );
    });
  });
}
