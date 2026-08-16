import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Huge Torrent Sync Skip & Adaptive Sync Intervals (P0-7)', () {
    test('Torrents with >10000 files skip expensive per-file progress queries', () {
      expect(TorrentDownloadHandler.shouldSkipPerFileSync(100), isFalse);
      expect(TorrentDownloadHandler.shouldSkipPerFileSync(1000), isFalse);
      expect(TorrentDownloadHandler.shouldSkipPerFileSync(5000), isFalse);
      expect(TorrentDownloadHandler.shouldSkipPerFileSync(10000), isFalse);
      expect(TorrentDownloadHandler.shouldSkipPerFileSync(10001), isTrue);
    });

    test('Sync interval is adaptive based on file count', () {
      // <= 100 files: 5s
      expect(
        TorrentDownloadHandler.computeAdaptiveSyncInterval(100),
        equals(const Duration(seconds: 5)),
      );

      // 1500 files (>1000 files): 30s
      expect(
        TorrentDownloadHandler.computeAdaptiveSyncInterval(1500),
        equals(const Duration(seconds: 30)),
      );

      // 6000 files (>5000 files): 45s
      expect(
        TorrentDownloadHandler.computeAdaptiveSyncInterval(6000),
        equals(const Duration(seconds: 45)),
      );

      // In background: fixed 60s
      expect(
        TorrentDownloadHandler.computeAdaptiveSyncInterval(1500, inBackground: true),
        equals(const Duration(seconds: 60)),
      );
    });
  });
}
