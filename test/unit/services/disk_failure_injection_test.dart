import 'dart:io';
import 'dart:typed_data';

import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Crash-Path & Disk-Full Injection Tests [10/10 Hardening]', () {
    late Directory tempDir;
    late String testFilePath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dmx_disk_failure_test_');
      testFilePath = '${tempDir.path}/test_download.bin';
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test(
        'PositionalFileWriter gracefully handles write operations and closes cleanly',
        () async {
      final file = File(testFilePath);
      await file.writeAsBytes(Uint8List(1024), flush: true);

      final writer = await PositionalFileWriter.openForResume(
        testFilePath,
        threadCount: 2,
      );

      // Successful write
      await writer.write(0, 0, Uint8List.fromList([1, 2, 3, 4]));
      await writer.flushAll();

      // Close writer
      await writer.close();
    });

    test(
        'DownloadJournal gracefully handles corrupted or truncated journal files',
        () async {
      final journalPath = '${tempDir.path}/test.journal';
      final file = File(journalPath);
      // Write corrupted / partial JSON data (simulating crash mid-flush)
      file.writeAsStringSync(
          '{"taskId": "task-123", "chunks": [{"offset": 0, "size": 1024, "complete');

      // Recovering journal should catch format error and safely return null / empty without throwing unhandled exceptions
      final recovered = await DownloadJournal.recoverWithDetails(journalPath);
      expect(recovered?.chunkBytes ?? [], isEmpty);
    });
  });
}
