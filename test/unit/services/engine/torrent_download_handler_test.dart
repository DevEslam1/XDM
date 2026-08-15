import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TorrentDownloadHandler', () {
    test('resets state fields properly', () {
      final handler = TorrentDownloadHandler();
      handler.lastStateLabel = 'downloading';
      handler.cachedAccurateFiles = [
        {'name': 'test.iso', 'length': 1000, 'downloadedBytes': 500}
      ];

      expect(handler.lastStateLabel, 'downloading');
      expect(handler.cachedAccurateFiles, isNotNull);

      // Normalization test
      final f = {'name': 'file1', 'length': 100, 'downloadedBytes': 150};
      TorrentDownloadHandler.normalizeTorrentFile(f);
      expect(f['downloadedBytes'], 100);
      expect(f['isComplete'], isTrue);
      expect(f['progress'], 1.0);
    });

    test('normalizeTorrentFiles aggregates counts correctly', () {
      final files = [
        {'name': 'f1', 'length': 100, 'downloadedBytes': 100, 'selected': true},
        {'name': 'f2', 'length': 200, 'downloadedBytes': 100, 'selected': true},
        {'name': 'f3', 'length': 300, 'downloadedBytes': 0, 'selected': false},
      ];
      final summary = TorrentDownloadHandler.normalizeTorrentFiles(files);
      expect(summary.total, 2);
      expect(summary.done, 1);
      expect(summary.bytes, 300);
      expect(summary.downloaded, 200);
    });

    test('distributeEstimatedBytes allocates remaining proportionally', () {
      final files = [
        {
          'name': 'f1',
          'length': 100,
          'downloadedBytes': 100,
          'progressEstimated': false
        },
        {
          'name': 'f2',
          'length': 100,
          'downloadedBytes': 0,
          'progressEstimated': true
        },
        {
          'name': 'f3',
          'length': 100,
          'downloadedBytes': 0,
          'progressEstimated': true
        },
      ];
      TorrentDownloadHandler.distributeEstimatedBytes(files, 200);
      expect(files[1]['downloadedBytes'], 50);
      expect(files[2]['downloadedBytes'], 50);
    });
  });
}
