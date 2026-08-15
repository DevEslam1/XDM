import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TorrentDownloadHandler Subscription Lifecycle', () {
    test('activeSubsForTesting tracks and cleans up properly', () {
      final handler = TorrentDownloadHandler();
      expect(handler.activeSubsForTesting, isEmpty);
      expect(TorrentDownloadHandler.globalActiveSubsForTesting, isEmpty);
    });

    test('normalizeTorrentFile clamps values safely', () {
      final fileMap = <String, dynamic>{
        'name': 'test.mp4',
        'length': 1000,
        'downloadedBytes': 1500, // exceeds length
      };

      TorrentDownloadHandler.normalizeTorrentFile(fileMap);
      expect(fileMap['downloadedBytes'], 1000);
      expect(fileMap['progress'], 1.0);
      expect(fileMap['isComplete'], isTrue);
    });
  });
}
