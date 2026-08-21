import 'dart:io';
import 'package:dmx/core/services/download_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadEngine.sweepStaleTempFiles (Data Integrity)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('stale_temp_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('sweeps stale .part and .tmp files older than maxAge', () async {
      final oldPart = File('${tempDir.path}/video.mp4.part');
      await oldPart.writeAsString('partial video data');
      final oldTmp = File('${tempDir.path}/download.tmp');
      await oldTmp.writeAsString('temp chunk data');

      // Set modification times in the past (e.g. 2 days ago)
      final pastDate = DateTime.now().subtract(const Duration(days: 2));
      await oldPart.setLastModified(pastDate);
      await oldTmp.setLastModified(pastDate);

      // Fresh file (modified just now)
      final freshFile = File('${tempDir.path}/fresh.mp4.part');
      await freshFile.writeAsString('fresh part');

      final deleted = await DownloadEngine.sweepStaleTempFiles(
        tempDir.path,
        maxAge: const Duration(hours: 24),
      );

      expect(deleted, 2);
      expect(await oldPart.exists(), isFalse);
      expect(await oldTmp.exists(), isFalse);
      expect(await freshFile.exists(), isTrue);
    });
  });
}
