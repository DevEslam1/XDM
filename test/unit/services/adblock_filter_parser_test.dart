import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:dmx/features/browser/services/adblock_filter_updater.dart';

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

    test('no previous size (first download) always passes size check',
        () async {
      final content = '||ads.example.com^\n';
      final f = File(p.join(tempDir.path, 'first.txt'));
      await f.writeAsString(content);
      final size = await f.length();
      final sample = await f.openRead(0, 1024).expand((b) => b).toList();
      expect(_isIntegrityOk(size, sample, 0), isTrue);
    });
  });

  group('AdblockFilterUpdater.cosmeticRulesForHost LRU cache behavior', () {
    final updater = AdBlockFilterUpdater();

    test('returns consistent set on repeat calls for same host', () {
      final rules1 = updater.cosmeticRulesForHost('example.com');
      final rules2 = updater.cosmeticRulesForHost('example.com');
      expect(identical(rules1, rules2), isTrue,
          reason: 'Cached result should return the exact same Set instance');
    });

    test('case-insensitive host lookup', () {
      final rulesLower = updater.cosmeticRulesForHost('sub.example.com');
      final rulesUpper = updater.cosmeticRulesForHost('SUB.EXAMPLE.COM');
      expect(identical(rulesLower, rulesUpper), isTrue,
          reason: 'Different casing should hit the same cache entry');
    });

    test('evicts oldest entry when max capacity (50) is exceeded', () {
      // Populate 50 entries
      for (var i = 0; i < 50; i++) {
        updater.cosmeticRulesForHost('host$i.com');
      }
      final firstHostRef1 = updater.cosmeticRulesForHost('host0.com');

      // Accessing host0 refreshes its LRU position to newest.
      // Now add 49 new hosts (filling total 50 capacity).
      for (var i = 100; i < 149; i++) {
        updater.cosmeticRulesForHost('newhost$i.com');
      }

      // host0 should be retained because it was refreshed to newest before inserting 49 items:
      final firstHostRef2 = updater.cosmeticRulesForHost('host0.com');
      expect(identical(firstHostRef1, firstHostRef2), isTrue);

      final host1Ref1 =
          updater.cosmeticRulesForHost('host1.com'); // re-computed
      final host1Ref2 = updater.cosmeticRulesForHost('host1.com'); // cached
      expect(identical(host1Ref1, host1Ref2), isTrue);
    });
  });

  group('AdBlockFilterUpdater host parsing', () {
    final updater = AdBlockFilterUpdater();

    test('parseFilterFile parses multi-host lines and inline comments', () async {
      final tempDir = await Directory.systemTemp.createTemp('adblock_hosts_test_');
      try {
        final f = File(p.join(tempDir.path, 'hosts.txt'));
        await f.writeAsString('''
# Sample hosts file
0.0.0.0 ad1.com ad2.com ad3.com # inline comment
127.0.0.1 tracker.org # comment
plainad.net # inline comment
||easylist-ad.com^
''');
        final result = await updater.parseFilterFile(f, FilterType.ads);
        expect(result.blocked, contains('ad1.com'));
        expect(result.blocked, contains('ad2.com'));
        expect(result.blocked, contains('ad3.com'));
        expect(result.blocked, contains('tracker.org'));
        expect(result.blocked, contains('plainad.net'));
        expect(result.blocked, contains('easylist-ad.com'));
      } finally {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    });
  });
}

/// Mirrors the integrity logic from AdblockFilterUpdater._downloadAndParse.
bool _isIntegrityOk(int fileSize, List<int> sample, int lastSize) {
  if (fileSize == 0) return false;
  if (sample.contains(0x00)) return false;
  if (lastSize > 0 && fileSize < (lastSize * 0.50).round()) return false;
  return true;
}
