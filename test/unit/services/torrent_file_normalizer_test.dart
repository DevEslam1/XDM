import 'package:dmx/core/services/engine/torrent_file_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TorrentFileNormalizer Tests', () {
    test('normalizeTorrentFile clamps downloadedBytes to 0..length', () {
      final negativeDl = {
        'name': 'test.bin',
        'length': 1000,
        'downloadedBytes': -50,
      };
      final normNegative =
          TorrentFileNormalizer.normalizeTorrentFile(negativeDl);
      expect(normNegative['downloadedBytes'], equals(0));
      expect(normNegative['progress'], equals(0.0));
      expect(normNegative['isComplete'], isFalse);

      final excessiveDl = {
        'name': 'test.bin',
        'length': 1000,
        'downloadedBytes': 2500,
      };
      final normExcessive =
          TorrentFileNormalizer.normalizeTorrentFile(excessiveDl);
      expect(normExcessive['downloadedBytes'], equals(1000));
      expect(normExcessive['progress'], equals(1.0));
      expect(normExcessive['isComplete'], isTrue);
    });

    test('normalizeTorrentFile treats a verified empty file as complete', () {
      final zeroFile = {
        'name': 'empty.txt',
        'length': 0,
        'lengthKnown': true,
        'downloadedBytes': 0,
      };
      final normZero = TorrentFileNormalizer.normalizeTorrentFile(zeroFile);
      expect(normZero['downloadedBytes'], equals(0));
      expect(normZero['progress'], equals(1.0));
      expect(normZero['isComplete'], isTrue);
    });

    test('normalizeTorrentFile treats an unresolved length as unknown', () {
      // The engine reports 0 for a size it cannot determine (e.g. a native
      // bridge that is not ABI-compatible). That must never read as complete.
      final unknown = {
        'name': 'ubuntu.iso',
        'length': 0,
        'downloadedBytes': 196608,
      };
      final norm = TorrentFileNormalizer.normalizeTorrentFile(unknown);
      expect(norm['lengthKnown'], isFalse);
      expect(norm['progress'], equals(0.0));
      expect(norm['isComplete'], isFalse);
      // The transferred bytes are real and are kept.
      expect(norm['downloadedBytes'], equals(196608));
    });

    test('normalizeTorrentFile honours isComplete only with a known length',
        () {
      final stale = {
        'name': 'ubuntu.iso',
        'length': 0,
        'downloadedBytes': 0,
        'isComplete': true,
      };
      final norm = TorrentFileNormalizer.normalizeTorrentFile(stale);
      expect(norm['isComplete'], isFalse);
    });

    test('resolveFileLength never lets a zero clobber a known length', () {
      expect(
        TorrentFileNormalizer.resolveFileLength(0, previousLength: 6100000000),
        equals(6100000000),
      );
      expect(
        TorrentFileNormalizer.resolveFileLength(2048, previousLength: 1024),
        equals(2048),
      );
      expect(TorrentFileNormalizer.resolveFileLength(0), equals(0));
    });

    test('normalizeTorrentFileList reports 0 done for all-unknown lengths', () {
      // Regression: a stale native file list (names only, sizes all 0) used to
      // aggregate as "every file complete".
      final result = TorrentFileNormalizer.normalizeTorrentFileList([
        {'name': 'ubuntu.iso', 'length': 0, 'downloadedBytes': 0},
      ]);
      expect(result.total, equals(1));
      expect(result.done, equals(0));
      expect(result.bytes, equals(0));
    });

    test('normalizeTorrentFile sets sensible defaults', () {
      final minimalFile = <String, dynamic>{
        'length': 500,
      };
      final norm = TorrentFileNormalizer.normalizeTorrentFile(minimalFile);
      expect(norm['name'], equals('file'));
      expect(norm['selected'], isTrue);
      expect(norm['priority'], equals(4));
      expect(norm['speed'], equals(0.0));
      expect(norm['progressEstimated'], isFalse);
      expect(norm['isComplete'], isFalse);
    });

    test(
        'normalizeTorrentFileList computes aggregates and detects progressEstimated',
        () {
      final files = [
        {
          'name': 'file1.mp4',
          'length': 1000,
          'downloadedBytes': 1000,
          'selected': true,
          'progressEstimated': false,
        },
        {
          'name': 'file2.mp4',
          'length': 2000,
          'downloadedBytes': 500,
          'selected': true,
          'progressEstimated': true,
        },
        {
          'name': 'file3.nfo',
          'length': 500,
          'downloadedBytes': 0,
          'selected': false, // Unselected file
          'progressEstimated': false,
        },
        {
          'name': 'file4.zero',
          'length': 0,
          // Verified empty by the torrent metadata, so it counts as done.
          'lengthKnown': true,
          'downloadedBytes': 0,
          'selected': true,
        },
      ];

      final result = TorrentFileNormalizer.normalizeTorrentFileList(files);

      // Selected files: file1 (1000/1000 done), file2 (500/2000), file4 (0/0 done) -> 3 selected
      expect(result.total, equals(3));
      // Done files: file1 and file4 -> 2 done
      expect(result.done, equals(2));
      // Total bytes: 1000 + 2000 + 0 = 3000
      expect(result.bytes, equals(3000));
      // Downloaded bytes: 1000 + 500 + 0 = 1500
      expect(result.downloaded, equals(1500));
      // One of the files has progressEstimated: true
      expect(result.hasEstimated, isTrue);
      // All 4 normalized files present
      expect(result.normalizedFiles.length, equals(4));
      expect(result.normalizedFiles[2]['selected'], isFalse);
    });

    test('normalizeTorrentFileList returns zeros on empty/null list', () {
      final emptyResult = TorrentFileNormalizer.normalizeTorrentFileList([]);
      expect(emptyResult.total, equals(0));
      expect(emptyResult.done, equals(0));
      expect(emptyResult.bytes, equals(0));
      expect(emptyResult.downloaded, equals(0));
      expect(emptyResult.hasEstimated, isFalse);
      expect(emptyResult.normalizedFiles, isEmpty);

      final nullResult = TorrentFileNormalizer.normalizeTorrentFileList(null);
      expect(nullResult.total, equals(0));
      expect(nullResult.hasEstimated, isFalse);
      expect(nullResult.normalizedFiles, isEmpty);
    });

    test('10000-entry file list normalizes and hashes efficiently', () {
      final bigList = List.generate(
        10000,
        (i) => {
          'name': 'folder/file_$i.dat',
          'length': 1024 * 1024,
          'downloadedBytes': i % 2 == 0 ? 1024 * 1024 : 512 * 1024,
          'selected': true,
        },
      );

      final sw = Stopwatch()..start();
      final result = TorrentFileNormalizer.normalizeTorrentFileList(bigList);
      final hash = TorrentFileNormalizer.computeFileListHash(bigList);
      sw.stop();

      expect(result.total, equals(10000));
      expect(result.done, equals(5000));
      expect(hash, isNonZero);
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });
  });
}
