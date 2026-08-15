import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Huge Torrent Sync Skip & Adaptive Sync Intervals (P0-7)', () {
    test('Torrents with >1000 files skip expensive per-file progress queries', () {
      expect(TorrentDownloadHandler.shouldSkipPerFileSync(100), isFalse);
      expect(TorrentDownloadHandler.shouldSkipPerFileSync(1000), isFalse);
      expect(TorrentDownloadHandler.shouldSkipPerFileSync(1001), isTrue);
      expect(TorrentDownloadHandler.shouldSkipPerFileSync(5000), isTrue);
    });

    test('Sync interval is adaptive based on file count', () {
      // 100 files: max(4000, 100 * 4) = 4000ms
      expect(
        TorrentDownloadHandler.computeAdaptiveSyncInterval(100),
        equals(const Duration(milliseconds: 4000)),
      );

      // 1500 files: max(4000, 1500 * 4) = 6000ms
      expect(
        TorrentDownloadHandler.computeAdaptiveSyncInterval(1500),
        equals(const Duration(milliseconds: 6000)),
      );

      // In background: fixed 30s
      expect(
        TorrentDownloadHandler.computeAdaptiveSyncInterval(1500, inBackground: true),
        equals(const Duration(seconds: 30)),
      );
    });
  });
}
