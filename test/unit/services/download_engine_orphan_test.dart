import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:path/path.dart' as p;

void main() {
  group('DownloadEngine Orphan Cleanup in Isolate (E-05)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('orphan_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('cleanupOrphanFiles cleans orphan parts quickly via isolate',
        () async {
      final mainPath = p.join(tempDir.path, 'video.mp4.dmxpart');
      final mainFile = File(mainPath);
      await mainFile.writeAsString('main part');

      final part1 = File(p.join(tempDir.path, 'video.mp4.part0'));
      final part2 = File(p.join(tempDir.path, 'video.mp4.part1'));
      final stateFile =
          File(p.join(tempDir.path, 'video.mp4.dmxpart.dmxstate'));

      await part1.writeAsString('part0');
      await part2.writeAsString('part1');
      await stateFile.writeAsString('state');

      final sw = Stopwatch()..start();
      final cleaned = await DownloadEngine.cleanupOrphanFiles(mainPath);
      sw.stop();

      expect(cleaned, greaterThanOrEqualTo(2));
      expect(await part1.exists(), isFalse);
      expect(await part2.exists(), isFalse);
      expect(await stateFile.exists(), isFalse);
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });
  });
}
