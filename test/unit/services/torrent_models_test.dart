import 'package:dmx/core/services/torrent_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Torrent Models Unit Tests', () {
    test('TorrentFileItem constructs with correct defaults', () {
      final item = TorrentFileItem(
        index: 0,
        name: 'video.mkv',
        size: 1048576,
      );

      expect(item.index, equals(0));
      expect(item.name, equals('video.mkv'));
      expect(item.size, equals(1048576));
      expect(item.downloadedBytes, equals(0));
      expect(item.priority, equals(4));
      expect(item.selected, isTrue);
    });

    test('TorrentUpdateInfo holds unmodifiable lists and properties', () {
      final info = TorrentUpdateInfo(
        id: 1,
        name: 'Ubuntu 24.04 ISO',
        progress: 0.75,
        downloadRate: 1024 * 1024,
        uploadRate: 512 * 1024,
        totalDone: 7500,
        totalWanted: 10000,
        totalWantedDone: 7500,
        hasMetadata: true,
        stateLabel: 'downloading',
        fileProgress: [100, 200],
        filePriorities: [4, 4],
      );

      expect(info.id, equals(1));
      expect(info.name, equals('Ubuntu 24.04 ISO'));
      expect(info.progress, equals(0.75));
      expect(info.hasMetadata, isTrue);
      expect(info.fileProgress.length, equals(2));
      expect(
          () => (info.fileProgress as List).add(300), throwsUnsupportedError);
    });

    test('TorrentTrackerInfo copyWith mutates specified fields', () {
      final tracker = TorrentTrackerInfo(
        url: 'udp://tracker.openbittorrent.com:80',
        status: TrackerStatus.working,
        seeds: 10,
        peers: 5,
      );

      final updated = tracker.copyWith(
        status: TrackerStatus.updating,
        peers: 20,
      );

      expect(updated.url, equals('udp://tracker.openbittorrent.com:80'));
      expect(updated.status, equals(TrackerStatus.updating));
      expect(updated.seeds, equals(10));
      expect(updated.peers, equals(20));
    });
  });
}
