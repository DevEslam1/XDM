import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:dmx/core/utils/file_utils.dart';

void main() {
  group('file_utils tests', () {
    test('safeFileName sanitizes invalid characters and reserved names', () {
      expect(safeFileName('video/test:name?.mp4'), 'video_test_name_.mp4');
      expect(safeFileName('CON.txt'), '_CON.txt');
      expect(safeFileName(''), 'download.bin');
    });

    test('getUniqueFilePath creates non-colliding filename when file exists', () async {
      final tempDir = await Directory.systemTemp.createTemp('dmx_file_utils_test_');
      try {
        final initialPath = p.join(tempDir.path, 'sample.mp4');
        await File(initialPath).writeAsString('test');

        final unique1 = await getUniqueFilePath(tempDir.path, 'sample.mp4');
        expect(p.basename(unique1), 'sample (1).mp4');

        await File(unique1).writeAsString('test 2');
        final unique2 = await getUniqueFilePath(tempDir.path, 'sample.mp4');
        expect(p.basename(unique2), 'sample (2).mp4');
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
