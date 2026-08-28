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
  });
}
