import 'package:dmx/core/domain/torrent_file_progress_estimator.dart';
import 'package:dmx/core/services/engine/torrent_file_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TorrentFileProgressEstimator Pure Domain Tests', () {
    // Regression: A3, M3
    test('weighted distribution proportional to length x priority', () {
      final files = [
        {
          'name': 'file1.mp4',
          'length': 1000,
          'priority': 4, // weight = 1.0 -> weighted length = 1000
          'selected': true,
          'downloadedBytes': 0,
          'progressEstimated': true,
        },
        {
          'name': 'file2.mp4',
          'length': 1000,
          'priority': 7, // weight = 1.5 -> weighted length = 1500
          'selected': true,
          'downloadedBytes': 0,
          'progressEstimated': true,
        },
      ];

      // Total weighted length = 2500. Total downloaded = 1000.
      // file1 share = 1000 * (1000 / 2500) = 400
      // file2 share = 1000 * (1500 / 2500) = 600
      TorrentFileProgressEstimator.distributeEstimatedBytes(files, 1000);

      expect(files[0]['downloadedBytes'], equals(400));
      expect(files[1]['downloadedBytes'], equals(600));
      expect(files[0]['progress'], closeTo(0.4, 0.001));
      expect(files[1]['progress'], closeTo(0.6, 0.001));
    });

    test('sequential fill order + monotonicity', () {
      final files = [
        {
          'name': 'part1.rar',
          'length': 500,
          'selected': true,
          'downloadedBytes': 0,
        },
        {
          'name': 'part2.rar',
          'length': 500,
          'selected': true,
          'downloadedBytes': 0,
        },
        {
          'name': 'part3.rar',
          'length': 500,
          'selected': true,
          'downloadedBytes': 0,
        },
      ];

      TorrentFileProgressEstimator.distributeEstimatedBytesSequential(
          files, 750);

      expect(files[0]['downloadedBytes'], equals(500));
      expect(files[0]['isComplete'], isTrue);
      expect(files[0]['progress'], equals(1.0));

      expect(files[1]['downloadedBytes'], equals(250));
      expect(files[1]['isComplete'], isFalse);
      expect(files[1]['progress'], equals(0.5));

      expect(files[2]['downloadedBytes'], equals(0));
      expect(files[2]['isComplete'], isFalse);
      expect(files[2]['progress'], equals(0.0));
    });

    test('unselected files are zeroed out', () {
      final files = [
        {
          'name': 'selected.mp4',
          'length': 1000,
          'selected': true,
          'downloadedBytes': 0,
          'progressEstimated': true,
        },
        {
          'name': 'unselected.txt',
          'length': 500,
          'selected': false,
          'downloadedBytes': 200,
          'progressEstimated': true,
        },
      ];

      TorrentFileProgressEstimator.distributeEstimatedBytes(files, 500);

      expect(files[0]['downloadedBytes'], equals(500));
      expect(files[1]['downloadedBytes'], equals(0));
      expect(files[1]['progress'], equals(0.0));
      expect(files[1]['isComplete'], isFalse);
    });

    test('zero-length files are marked complete if selected', () {
      final file = {
        'name': 'empty.nfo',
        'length': 0,
        'lengthKnown': true,
        'selected': true,
        'downloadedBytes': 0,
      };

      final normalized = TorrentFileNormalizer.normalizeTorrentFile(file);
      expect(normalized['isComplete'], isTrue);
      expect(normalized['progress'], equals(1.0));
    });

    test('corrupt inputs (-1, null, > length) handled safely', () {
      final files = [
        {
          'name': 'valid.bin',
          'length': 1000,
          'downloadedBytes': -1,
          'selected': true,
        },
        {
          'name': 'overflow.bin',
          'length': 1000,
          'downloadedBytes': 5000,
          'selected': true,
        },
      ];

      TorrentFileProgressEstimator.updateFilesWithNativeProgress(
        files,
        0.5,
        500,
      );

      // Overflows and negative values are clamped to [0, length]
      expect(files[0]['downloadedBytes'], inInclusiveRange(0, 1000));
      expect(files[1]['downloadedBytes'], inInclusiveRange(0, 1000));
    });

    test('reconcile caps at length and last file absorbs rounding', () {
      final files = [
        {
          'name': 'f1',
          'length': 100,
          'downloadedBytes': 33,
          'progressEstimated': true,
          'selected': true,
        },
        {
          'name': 'f2',
          'length': 100,
          'downloadedBytes': 33,
          'progressEstimated': true,
          'selected': true,
        },
        {
          'name': 'f3',
          'length': 100,
          'downloadedBytes': 33,
          'progressEstimated': true,
          'selected': true,
        },
      ];

      // Sum = 99, total is 100 -> diff = 1
      TorrentFileProgressEstimator.reconcileEstimatedFiles(files, 100);

      final total =
          files.fold<int>(0, (sum, f) => sum + (f['downloadedBytes'] as int));
      expect(total, equals(100));
    });

    test('priorityWeight maps priority bands', () {
      expect(TorrentFileProgressEstimator.priorityWeight(0), 0.0);
      expect(TorrentFileProgressEstimator.priorityWeight(-1), 0.0);
      expect(
          TorrentFileProgressEstimator.priorityWeight(1), closeTo(0.5, 0.001));
      expect(TorrentFileProgressEstimator.priorityWeight(4), 1.0);
      expect(TorrentFileProgressEstimator.priorityWeight(5),
          closeTo(1.1666, 0.001));
      expect(TorrentFileProgressEstimator.priorityWeight(7), 1.5);
      expect(TorrentFileProgressEstimator.priorityWeight(9), 1.5);
    });

    test('updateFilesWithNativeProgress handles empty list safely', () {
      TorrentFileProgressEstimator.updateFilesWithNativeProgress([], 0.5, 100);
    });

    test('updateFilesWithNativeProgress covers all branches', () {
      final files = [
        {
          'name': 'unselected',
          'length': 100,
          'selected': false,
          'downloadedBytes': 50,
        },
        {
          'name': 'zero-length',
          'length': 0,
          'selected': true,
          'downloadedBytes': 0,
        },
        {
          'name': 'exact',
          'length': 100,
          'selected': true,
          'downloadedBytes': 50,
        },
        {
          'name': 'estimate',
          'length': 100,
          'selected': true,
          'downloadedBytes': 0,
        },
        {
          'name': 'fresh',
          'length': 100,
          'selected': true,
          'downloadedBytes': -1,
        },
        {
          'name': 'overflow',
          'length': 100,
          'selected': true,
          'downloadedBytes': 1000,
        },
      ];

      TorrentFileProgressEstimator.updateFilesWithNativeProgress(
          files, 0.5, 100);

      expect(files[0]['downloadedBytes'], 0);
      expect(files[1]['progressEstimated'], isTrue);
      expect(files[2]['progressEstimated'], isFalse);
      expect(files[2]['progress'], closeTo(0.5, 0.001));
      expect(files[5]['downloadedBytes'], lessThanOrEqualTo(100));
    });

    test('updateFilesWithNativeProgress with zero total skips distribution',
        () {
      final files = [
        {
          'name': 'fresh',
          'length': 100,
          'selected': true,
          'downloadedBytes': 0,
        },
      ];
      TorrentFileProgressEstimator.updateFilesWithNativeProgress(files, 0.5, 0);
      expect(files[0]['downloadedBytes'], 0);
    });

    test('updateFilesWithNativeProgress sequential path', () {
      final files = [
        {'name': 'a', 'length': 100, 'selected': true, 'downloadedBytes': 0},
        {'name': 'b', 'length': 100, 'selected': true, 'downloadedBytes': 0},
      ];
      TorrentFileProgressEstimator.updateFilesWithNativeProgress(
          files, 0.5, 150,
          sequential: true);
      expect(files[0]['downloadedBytes'], 100);
      expect(files[1]['downloadedBytes'], 50);
    });

    test('applyNativeFileProgress uses native data when available', () {
      final files = [
        {'name': 'a', 'length': 100, 'selected': true, 'downloadedBytes': 0},
        {'name': 'b', 'length': 100, 'selected': false, 'downloadedBytes': 0},
        {'name': 'c', 'length': 0, 'selected': true, 'downloadedBytes': 0},
        {'name': 'd', 'length': 100, 'selected': true, 'downloadedBytes': 0},
      ];
      TorrentFileProgressEstimator.applyNativeFileProgress(
          files, [50, 60, 5, 500], 0.5, 100);
      expect(files[0]['downloadedBytes'], 50);
      expect(files[1]['downloadedBytes'], 0);
      expect(files[2]['downloadedBytes'], 5);
      expect(files[3]['downloadedBytes'], 100);
      expect(files[0]['progressEstimated'], isFalse);
    });

    test('applyNativeFileProgress falls back to estimation', () {
      final files = [
        {'name': 'a', 'length': 100, 'selected': true, 'downloadedBytes': 0},
      ];
      TorrentFileProgressEstimator.applyNativeFileProgress(
          files, const [], 0.5, 100);
      expect(files[0]['downloadedBytes'], greaterThan(0));
    });

    test('distributeEstimatedBytes returns when nothing needing', () {
      final files = [
        {
          'name': 'complete',
          'length': 100,
          'selected': true,
          'downloadedBytes': 100,
          'progressEstimated': false,
        },
      ];
      TorrentFileProgressEstimator.distributeEstimatedBytes(files, 100);
      expect(files[0]['downloadedBytes'], 100);
    });

    test('distributeEstimatedBytes zero-weight even share branch', () {
      final files = [
        {
          'name': 'a',
          'length': 100,
          'selected': true,
          'downloadedBytes': 0,
          'progressEstimated': true,
          'priority': 0,
        },
        {
          'name': 'b',
          'length': 100,
          'selected': true,
          'downloadedBytes': 0,
          'progressEstimated': true,
          'priority': 0,
        },
      ];
      TorrentFileProgressEstimator.distributeEstimatedBytes(files, 101);
      expect(files[0]['downloadedBytes'], 51);
      expect(files[1]['downloadedBytes'], 50);
    });

    test('distributeEstimatedBytes zero-length file in even share branch', () {
      final files = [
        {
          'name': 'a',
          'length': 0,
          'selected': true,
          'downloadedBytes': 0,
          'progressEstimated': true,
          'priority': 0,
        },
      ];
      TorrentFileProgressEstimator.distributeEstimatedBytes(files, 10);
      expect(files[0]['downloadedBytes'], 0);
    });

    test('distributeEstimatedBytes proportional branch caps at length', () {
      final files = [
        {
          'name': 'a',
          'length': 100,
          'selected': true,
          'downloadedBytes': 0,
          'progressEstimated': true,
          'priority': 4,
        },
        {
          'name': 'b',
          'length': 100,
          'selected': true,
          'downloadedBytes': 0,
          'progressEstimated': true,
          'priority': 4,
        },
      ];
      TorrentFileProgressEstimator.distributeEstimatedBytes(files, 500);
      expect(files[0]['downloadedBytes'], 100);
      expect(files[1]['downloadedBytes'], 100);
    });

    test('reconcileEstimatedFiles handles positive, negative and no-op', () {
      TorrentFileProgressEstimator.reconcileEstimatedFiles([], 0);
      TorrentFileProgressEstimator.reconcileEstimatedFiles([
        {
          'length': 100,
          'downloadedBytes': 100,
          'progressEstimated': true,
          'selected': true,
        }
      ], 100);

      final under = [
        {
          'length': 100,
          'downloadedBytes': 10,
          'progressEstimated': true,
          'selected': true,
        },
        {
          'length': 100,
          'downloadedBytes': 10,
          'progressEstimated': true,
          'selected': true,
        },
      ];
      TorrentFileProgressEstimator.reconcileEstimatedFiles(under, 100);
      final sum =
          under.fold<int>(0, (s, f) => s + (f['downloadedBytes'] as int));
      expect(sum, 100);

      final over = [
        {
          'length': 100,
          'downloadedBytes': 50,
          'progressEstimated': true,
          'selected': true,
        },
        {
          'length': 100,
          'downloadedBytes': 50,
          'progressEstimated': true,
          'selected': true,
        },
      ];
      TorrentFileProgressEstimator.reconcileEstimatedFiles(over, 40);
      final overSum =
          over.fold<int>(0, (s, f) => s + (f['downloadedBytes'] as int));
      expect(overSum, lessThanOrEqualTo(100));
    });

    test('reconcileEstimatedFiles negative with no estimated downloads', () {
      final files = [
        {
          'length': 100,
          'downloadedBytes': 50,
          'progressEstimated': false,
          'selected': true,
        },
      ];
      TorrentFileProgressEstimator.reconcileEstimatedFiles(files, 10);
      expect(files[0]['downloadedBytes'], 50);
    });
  });
}
