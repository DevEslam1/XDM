import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/data/task_repository.dart';
import 'package:dmx/features/downloads/provider/torrent_lifecycle_manager.dart';
import 'package:dmx/core/services/torrent_service.dart';

void main() {
  late InMemoryTaskRepository repo;
  late TorrentLifecycleManager torrentManager;
  final Map<String, int> torrentIds = {};
  final Map<int, TorrentUpdateInfo> latestTorrentStats = {};

  setUp(() {
    repo = InMemoryTaskRepository();
    torrentIds.clear();
    latestTorrentStats.clear();
    torrentManager = TorrentLifecycleManager(
      torrentIds: torrentIds,
      latestTorrentStats: latestTorrentStats,
    );
  });

  tearDown(() {
    repo.dispose();
  });

  DownloadTask createTorrentTask(String id, DownloadStatus status) {
    final now = DateTime.now();
    return DownloadTask(
      id: id,
      fileName: 'ubuntu.iso',
      url: 'magnet:?xt=urn:btih:123456789abcdef',
      fileSize: 1000000,
      downloadedBytes: 0,
      category: 'Operating Systems',
      status: status,
      savePath: '/downloads',
      localFilePath: '/downloads/ubuntu.iso',
      tempFilePath: '/downloads/ubuntu.iso.tmp',
      threadCount: 4,
      chunks: const [0.0],
      createdAt: now,
      updatedAt: now,
      seedingEnabled: true,
    );
  }

  group('Torrent Lifecycle Integration', () {
    test('1. Add magnet → status is queued/downloading', () async {
      final task = createTorrentTask('t1', DownloadStatus.queued);
      await repo.save(task);

      final loaded = await repo.getById('t1');
      expect(loaded, isNotNull);
      expect(loaded!.isTorrent, isTrue);
      expect(loaded.status, equals(DownloadStatus.queued));
    });

    test('2. Torrent completes → seeding starts if enabled', () async {
      final task = createTorrentTask('t2', DownloadStatus.downloading);
      await repo.save(task);

      final completed = task.copyWith(status: DownloadStatus.completed);
      await repo.save(completed);

      final loaded = await repo.getById('t2');
      expect(loaded!.status, equals(DownloadStatus.completed));
      expect(loaded.seedingEnabled, isTrue);
    });

    test('3. Torrent pause → stats cleared', () async {
      torrentIds['t3'] = 101;
      latestTorrentStats[101] = TorrentUpdateInfo(
        id: 101,
        name: 't3',
        downloadRate: 1024,
        uploadRate: 512,
        numSeeds: 10,
        numPeers: 20,
        progress: 0.5,
        totalDone: 500,
        totalWanted: 1000,
        totalWantedDone: 500,
        hasMetadata: true,
        stateLabel: 'downloading',
        piecesHave: 50,
        piecesTotal: 100,
        downloadPayloadRate: 1000,
        uploadPayloadRate: 500,
        totalPayloadDownload: 500,
        totalPayloadUpload: 250,
        currentTracker: '',
        nextAnnounceSeconds: 0,
      );

      expect(torrentManager.getUploadSpeed('t3'), equals(512.0));
      expect(torrentManager.getSeeds('t3'), equals(10));
      expect(torrentManager.getPeers('t3'), equals(20));
    });

    test('4. Torrent resume → resume stats query', () async {
      torrentIds['t4'] = 102;
      latestTorrentStats[102] = TorrentUpdateInfo(
        id: 102,
        name: 't4',
        downloadRate: 2048,
        uploadRate: 1024,
        numSeeds: 15,
        numPeers: 30,
        progress: 0.8,
        totalDone: 800,
        totalWanted: 1000,
        totalWantedDone: 800,
        hasMetadata: true,
        stateLabel: 'downloading',
        piecesHave: 80,
        piecesTotal: 100,
        downloadPayloadRate: 2000,
        uploadPayloadRate: 1000,
        totalPayloadDownload: 800,
        totalPayloadUpload: 400,
        currentTracker: '',
        nextAnnounceSeconds: 0,
      );

      expect(torrentManager.getUploadSpeed('t4'), equals(1024.0));
    });
  });
}
