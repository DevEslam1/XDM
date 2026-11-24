import 'package:dmx/core/services/engine/torrent_file_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isTorrentFileSelected', () {
    test('defaults to true and honors explicit false', () {
      expect(TorrentFileNormalizer.isTorrentFileSelected({}), isTrue);
      expect(TorrentFileNormalizer.isTorrentFileSelected({'selected': false}),
          isFalse);
    });
  });

  group('resolveFileLength', () {
    test('native size wins when positive', () {
      expect(
          TorrentFileNormalizer.resolveFileLength(50, previousLength: 10), 50);
    });

    test('falls back to previous length when native is 0', () {
      expect(
          TorrentFileNormalizer.resolveFileLength(0, previousLength: 10), 10);
      expect(
          TorrentFileNormalizer.resolveFileLength(-1, previousLength: 10), 10);
    });

    test('returns 0 when nothing is known', () {
      expect(TorrentFileNormalizer.resolveFileLength(0), 0);
      expect(TorrentFileNormalizer.resolveFileLength(0, previousLength: 0), 0);
      expect(
          TorrentFileNormalizer.resolveFileLength(-5, previousLength: -2), 0);
    });
  });

  group('isLengthKnown', () {
    test('positive length is known', () {
      expect(TorrentFileNormalizer.isLengthKnown({'length': 5}), isTrue);
    });

    test('zero length known only via lengthKnown flag', () {
      expect(
          TorrentFileNormalizer.isLengthKnown(
              {'length': 0, 'lengthKnown': true}),
          isTrue);
      expect(
          TorrentFileNormalizer.isLengthKnown(
              {'length': 0, 'lengthKnown': false}),
          isFalse);
      expect(TorrentFileNormalizer.isLengthKnown({'length': 0}), isFalse);
      expect(TorrentFileNormalizer.isLengthKnown({}), isFalse);
    });
  });

  group('normalizeTorrentFile', () {
    test('selected file with known length clamps bytes and progress', () {
      final out = TorrentFileNormalizer.normalizeTorrentFile({
        'name': 'a.mp4',
        'length': 100,
        'downloadedBytes': 250,
        'selected': true,
      });
      expect(out['downloadedBytes'], 100);
      expect(out['progress'], 1.0);
      expect(out['isComplete'], isTrue);
      expect(out['priority'], 4);
      expect(out['speed'], 0.0);
    });

    test('deselected file zeroes progress and marks not complete', () {
      final out = TorrentFileNormalizer.normalizeTorrentFile({
        'name': 'b.bin',
        'length': 100,
        'downloadedBytes': 50,
        'selected': false,
        'priority': 0,
      });
      expect(out['downloadedBytes'], 0);
      expect(out['progress'], 0.0);
      expect(out['isComplete'], isFalse);
      expect(out['priority'], 0);
    });

    test('unknown length keeps real bytes but not complete', () {
      final out = TorrentFileNormalizer.normalizeTorrentFile({
        'name': 'c',
        'length': 0,
        'downloadedBytes': 42,
      });
      expect(out['downloadedBytes'], 42);
      expect(out['progress'], 0.0);
      expect(out['isComplete'], isFalse);
    });

    test('verified empty file is complete', () {
      final out = TorrentFileNormalizer.normalizeTorrentFile({
        'name': 'empty',
        'length': 0,
        'lengthKnown': true,
      });
      expect(out['lengthKnown'], isTrue);
      expect(out['progress'], 1.0);
      expect(out['isComplete'], isTrue);
    });

    test('negative downloaded bytes clamp to zero for unknown length', () {
      final out = TorrentFileNormalizer.normalizeTorrentFile({
        'name': 'neg',
        'length': 0,
        'downloadedBytes': -5,
      });
      expect(out['downloadedBytes'], 0);
    });

    test('explicit isComplete is honored when length known and not estimated',
        () {
      final out = TorrentFileNormalizer.normalizeTorrentFile({
        'name': 'x',
        'length': 10,
        'downloadedBytes': 1,
        'isComplete': true,
      });
      expect(out['isComplete'], isTrue);
    });

    test('estimated progress prevents implicit completion', () {
      final out = TorrentFileNormalizer.normalizeTorrentFile({
        'name': 'x',
        'length': 10,
        'downloadedBytes': 10,
        'progressEstimated': true,
      });
      expect(out['isComplete'], isFalse);
      expect(out['progressEstimated'], isTrue);
    });

    test('missing name defaults to file', () {
      final out = TorrentFileNormalizer.normalizeTorrentFile({'length': 1});
      expect(out['name'], 'file');
    });
  });

  group('normalizeTorrentFileList', () {
    test('empty/null input returns zeroed record', () {
      final result = TorrentFileNormalizer.normalizeTorrentFileList(null);
      expect(result.total, 0);
      expect(result.done, 0);
      expect(result.bytes, 0);
      expect(result.downloaded, 0);
      expect(result.hasEstimated, isFalse);
      expect(result.normalizedFiles, isEmpty);
      expect(TorrentFileNormalizer.normalizeTorrentFileList([]).total, 0);
    });

    test('aggregates selected files and flags estimated', () {
      final result = TorrentFileNormalizer.normalizeTorrentFileList([
        {'name': 'a', 'length': 100, 'downloadedBytes': 100},
        {
          'name': 'b',
          'length': 200,
          'downloadedBytes': 50,
          'progressEstimated': true,
        },
        {'name': 'skip', 'length': 10, 'selected': false},
        'not-a-map',
      ]);
      expect(result.total, 2);
      expect(result.done, 1);
      expect(result.bytes, 300);
      expect(result.downloaded, 150);
      expect(result.hasEstimated, isTrue);
      expect(result.normalizedFiles.length, 3);
    });

    test('falls back to all files when none selected', () {
      final result = TorrentFileNormalizer.normalizeTorrentFileList([
        {'name': 'a', 'length': 100, 'downloadedBytes': 100, 'selected': false},
        {'name': 'b', 'length': 200, 'downloadedBytes': 0, 'selected': false},
      ]);
      expect(result.total, 2);
      expect(result.bytes, 300);
      expect(result.downloaded, 0);
      expect(result.done, 0);
    });

    test('unknown-length entries are not counted as downloaded', () {
      final result = TorrentFileNormalizer.normalizeTorrentFileList([
        {'name': 'u', 'length': 0, 'downloadedBytes': 500},
      ]);
      expect(result.total, 1);
      expect(result.downloaded, 0);
      expect(result.done, 0);
    });

    test('fallback counts a verified empty file as done', () {
      final result = TorrentFileNormalizer.normalizeTorrentFileList([
        {'name': 'e', 'length': 0, 'lengthKnown': true, 'selected': false},
      ]);
      expect(result.total, 1);
      expect(result.done, 1);
    });
  });

  group('computeFileListHash', () {
    test('null/empty returns 0 and stable for equal lists', () {
      expect(TorrentFileNormalizer.computeFileListHash(null), 0);
      expect(TorrentFileNormalizer.computeFileListHash([]), 0);
      final a = TorrentFileNormalizer.computeFileListHash([
        {'name': 'a', 'length': 1, 'downloadedBytes': 0, 'priority': 4},
      ]);
      final b = TorrentFileNormalizer.computeFileListHash([
        {'name': 'a', 'length': 1, 'downloadedBytes': 0, 'priority': 4},
      ]);
      expect(a, b);
    });

    test('changes when a field changes', () {
      final a = TorrentFileNormalizer.computeFileListHash([
        {'name': 'a', 'length': 1, 'downloadedBytes': 0},
      ]);
      final b = TorrentFileNormalizer.computeFileListHash([
        {'name': 'a', 'length': 1, 'downloadedBytes': 5},
      ]);
      expect(a, isNot(b));
    });
  });

  group('computeOverallProgress / computeFileProgress', () {
    test('overall progress handles null/empty/no-selection', () {
      expect(TorrentFileNormalizer.computeOverallProgress(null), 0.0);
      expect(TorrentFileNormalizer.computeOverallProgress([]), 0.0);
      expect(
          TorrentFileNormalizer.computeOverallProgress([
            {'selected': false, 'length': 10, 'downloadedBytes': 10},
          ]),
          0.0);
    });

    test('overall progress aggregates selected files', () {
      final p = TorrentFileNormalizer.computeOverallProgress([
        {'selected': true, 'length': 100, 'downloadedBytes': 50},
        {'selected': true, 'length': 100, 'downloadedBytes': 100},
        {'selected': false, 'length': 100, 'downloadedBytes': 0},
      ]);
      expect(p, closeTo(0.75, 0.0001));
    });

    test('file progress returns 0 for unknown length and clamps', () {
      expect(TorrentFileNormalizer.computeFileProgress({'length': 0}), 0.0);
      expect(
          TorrentFileNormalizer.computeFileProgress(
              {'length': 10, 'downloadedBytes': 20}),
          1.0);
      expect(
          TorrentFileNormalizer.computeFileProgress(
              {'length': 10, 'downloadedBytes': 5}),
          0.5);
    });
  });

  group('format helpers', () {
    test('formatFilesSummary handles zero and clamps', () {
      expect(
          TorrentFileNormalizer.formatFilesSummary(
              totalFiles: 0, completedFiles: 0),
          '—');
      expect(
          TorrentFileNormalizer.formatFilesSummary(
              totalFiles: 10, completedFiles: 3),
          '3/10 FILES');
      expect(
          TorrentFileNormalizer.formatFilesSummary(
              totalFiles: 10, completedFiles: 99),
          '10/10 FILES');
    });

    test('formatSummaryFromFiles derives from list', () {
      expect(TorrentFileNormalizer.formatSummaryFromFiles(null), '—');
      expect(TorrentFileNormalizer.formatSummaryFromFiles([]), '—');
      expect(
          TorrentFileNormalizer.formatSummaryFromFiles([
            {'name': 'a', 'length': 10, 'downloadedBytes': 10},
            {'name': 'b', 'length': 10, 'downloadedBytes': 0},
          ]),
          '1/2 FILES');
    });
  });
}
