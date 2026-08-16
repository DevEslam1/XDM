import 'dart:async';
import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTorrentService extends Fake implements ITorrentService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TorrentDownloadHandler Resource Cleanup (P1-08)', () {
    test('removeActiveTorrent releases cachedAccurateFiles, lastStateLabel, and subscriptions', () {
      final handler = TorrentDownloadHandler(torrentService: _FakeTorrentService());

      // Seed state simulating an active transfer
      handler.cachedAccurateFiles = [
        {'name': 'video.mp4', 'length': 1048576, 'completed': 524288},
      ];
      handler.lastStateLabel = 'Downloading (50%)';

      final dummySub = const Stream<void>.empty().listen((_) {});
      handler.activeSubsForTesting[101] = dummySub;

      expect(handler.cachedAccurateFiles, isNotNull);
      expect(handler.lastStateLabel, equals('Downloading (50%)'));
      expect(handler.activeSubsForTesting.containsKey(101), isTrue);

      // Trigger cleanup
      handler.removeActiveTorrent(101);

      expect(handler.cachedAccurateFiles, isNull);
      expect(handler.lastStateLabel, isEmpty);
      expect(handler.activeSubsForTesting.containsKey(101), isFalse);
      expect(handler.stallWatchdogForTesting, isNull);
    });
  });
}
