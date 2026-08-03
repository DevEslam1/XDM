import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  /// These tests verify the integrity check logic used in AdblockFilterUpdater._downloadAndParse.
  /// We mirror the same checks here to prevent regressions.
  group('AdblockFilterUpdater integrity checks', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('adblock_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('empty file is rejected', () async {
      final f = File(p.join(tempDir.path, 'empty.txt'));
      await f.writeAsBytes([]);
      final size = await f.length();
      expect(size, equals(0), reason: 'File should be empty');
      expect(_isIntegrityOk(size, [], 0), isFalse);
    });

    test('normal text filter file passes', () async {
      final content = '||ads.example.com^\n||tracker.io^\n';
      final f = File(p.join(tempDir.path, 'filter.txt'));
      await f.writeAsString(content);
      final size = await f.length();
      final sample = await f.openRead(0, 1024).expand((b) => b).toList();
      expect(_isIntegrityOk(size, sample, 0), isTrue);
    });

    test('file with null bytes (binary) is rejected', () async {
      final f = File(p.join(tempDir.path, 'binary.txt'));
      await f.writeAsBytes([0x41, 0x42, 0x00, 0x43]); // 'AB\0C'
      final size = await f.length();
      final sample = await f.openRead(0, 1024).expand((b) => b).toList();
      expect(_isIntegrityOk(size, sample, 0), isFalse);
    });

    test('file much smaller than last good size is rejected', () async {
      final tiny = '||a.com^\n';
      final f = File(p.join(tempDir.path, 'tiny.txt'));
      await f.writeAsString(tiny);
      final size = await f.length();
      final sample = await f.openRead(0, 1024).expand((b) => b).toList();
      final lastGoodSize = size * 100;
      expect(_isIntegrityOk(size, sample, lastGoodSize), isFalse);
    });

    test('file slightly smaller than last good size passes', () async {
      final content = List.generate(500, (i) => '||domain$i.com^').join('\n');
      final f = File(p.join(tempDir.path, 'normal.txt'));
      await f.writeAsString(content);
      final size = await f.length();
      final sample = await f.openRead(0, 1024).expand((b) => b).toList();
      final lastGoodSize = (size * 1.1).round();
      expect(_isIntegrityOk(size, sample, lastGoodSize), isTrue);
    });

    test('no previous size (first download) always passes size check', () async {
      final content = '||ads.example.com^\n';
      final f = File(p.join(tempDir.path, 'first.txt'));
      await f.writeAsString(content);
      final size = await f.length();
      final sample = await f.openRead(0, 1024).expand((b) => b).toList();
      expect(_isIntegrityOk(size, sample, 0), isTrue);
    });
  });
}

/// Mirrors the integrity logic from AdblockFilterUpdater._downloadAndParse.
bool _isIntegrityOk(int fileSize, List<int> sample, int lastSize) {
  if (fileSize == 0) return false;
  if (sample.contains(0x00)) return false;
  if (lastSize > 0 && fileSize < (lastSize * 0.30).round()) return false;
  return true;
}
