import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/mixins/download_torrent_mixin.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDb extends DatabaseService {
  _FakeDb() : super.forSubclass();
  final List<DownloadTask> saved = [];
  @override
  Future<void> saveTask(DownloadTask task) async {
    saved.add(task);
  }
}

class _TorrentHost with DownloadTorrentMixin {
  _TorrentHost(this.settings, this.db);

  final SettingsProvider settings;
  final _FakeDb db;
  final List<DownloadTask> tasks = [];
  final Map<String, int> torrentIds = {};
  final Map<int, TorrentUpdateInfo> stats = {};
  bool filteredDirty = false;
  int notifyCount = 0;
  int widgetTimerCount = 0;

  @override
  List<DownloadTask> get providerTasks => tasks;
  @override
  Map<String, int> get providerTorrentIds => torrentIds;
  @override
  Map<int, TorrentUpdateInfo> get providerLatestTorrentStats => stats;
  @override
  SettingsProvider get providerSettingsProvider => settings;
  @override
  DatabaseService get providerDatabaseService => db;
  @override
  DownloadTask? findTaskById(String id) {
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  @override
  void updateProgressTask(DownloadTask updated) {
    final i = tasks.indexWhere((t) => t.id == updated.id);
    if (i != -1) tasks[i] = updated;
  }

  @override
  void providerNotifyListeners() => notifyCount++;
  @override
  void providerStartWidgetTimer() => widgetTimerCount++;
  @override
  set filteredTasksDirty(bool value) => filteredDirty = value;
  @override
  bool get providerIsOnWifi => true;
  @override
  bool get providerIsCharging => false;
}

DownloadTask _torrent(
  String id, {
  DownloadStatus status = DownloadStatus.downloading,
  bool seedingEnabled = false,
  int fileSize = 1000,
  int downloadedBytes = 0,
  DateTime? completedAt,
  List<Map<String, dynamic>>? torrentFiles,
  int speed = 0,
}) {
  final now = DateTime(2026, 1, 1);
  return DownloadTask(
    id: id,
    fileName: '$id.torrent',
    url: 'magnet:?xt=urn:btih:$id',
    fileSize: fileSize,
    downloadedBytes: downloadedBytes,
    category: 'Torrent',
    status: status,
    savePath: '/d',
    localFilePath: '/d/$id',
    tempFilePath: '/d/$id.dmxpart',
    threadCount: 2,
    chunks: const [0.0, 0.0],
    createdAt: now,
    updatedAt: now,
    completedAt: completedAt,
    seedingEnabled: seedingEnabled,
    speed: speed.toDouble(),
    torrentFiles: torrentFiles,
  );
}

TorrentUpdateInfo _stat(
  int id, {
  String stateLabel = 'Seeding',
  int uploadRate = 0,
  int downloadRate = 0,
  int totalPayloadUpload = 0,
  int totalPayloadDownload = 0,
  int numSeeds = 3,
  int numPeers = 4,
  int? numComplete,
  int? numIncomplete,
  double distributedCopies = 1.0,
  double progress = 1.0,
}) {
  return TorrentUpdateInfo(
    id: id,
    name: 'torrent $id',
    progress: progress,
    downloadRate: downloadRate,
    uploadRate: uploadRate,
    totalDone: 0,
    totalWanted: 1000,
    totalWantedDone: 0,
    hasMetadata: true,
    stateLabel: stateLabel,
    numSeeds: numSeeds,
    numPeers: numPeers,
    numComplete: numComplete,
    numIncomplete: numIncomplete,
    distributedCopies: distributedCopies,
    totalPayloadUpload: totalPayloadUpload,
    totalPayloadDownload: totalPayloadDownload,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (methodCall) async => null,
    );
  });

  late SettingsProvider settings;
  late _FakeDb db;
  late _TorrentHost host;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsProvider();
    await settings.load();
    db = _FakeDb();
    host = _TorrentHost(settings, db);
  });

  group('aggregate getters', () {
    test('currentUploadSpeed sums seeding torrents', () {
      host.tasks.add(_torrent('a',
          status: DownloadStatus.completed, seedingEnabled: true, speed: 100));
      host.tasks.add(_torrent('b',
          status: DownloadStatus.completed, seedingEnabled: true, speed: 50));
      host.tasks.add(_torrent('c', status: DownloadStatus.downloading));
      expect(host.currentUploadSpeed, 150);
      expect(host.currentUploadSpeedFormatted, contains('/s'));
    });

    test('seedingTasksCount counts completed seeding torrents', () {
      host.tasks.add(_torrent('a',
          status: DownloadStatus.completed, seedingEnabled: true));
      host.tasks.add(_torrent('b', status: DownloadStatus.completed));
      expect(host.seedingTasksCount, 1);
    });
  });

  group('getTorrentSwarm', () {
    test('missing task returns empty', () {
      expect(host.getTorrentSwarm('nope').isEmpty, isTrue);
    });

    test('returns empty when bridge is incompatible', () {
      final prev = TorrentService.bridgeCompatible;
      TorrentService.bridgeCompatible = false;
      addTearDown(() => TorrentService.bridgeCompatible = prev);
      host.tasks.add(_torrent('a'));
      expect(host.getTorrentSwarm('a').isEmpty, isTrue);
    });

    test('builds a snapshot from stats and clamps negatives', () {
      final prev = TorrentService.bridgeCompatible;
      TorrentService.bridgeCompatible = true;
      addTearDown(() => TorrentService.bridgeCompatible = prev);
      host.tasks.add(_torrent('a'));
      host.torrentIds['a'] = 1;
      host.stats[1] = _stat(1,
          numSeeds: -1,
          numPeers: -2,
          numComplete: -1,
          numIncomplete: 5,
          distributedCopies: -3);
      final swarm = host.getTorrentSwarm('a');
      expect(swarm.connectedSeeds, 0);
      expect(swarm.connectedPeers, 0);
      expect(swarm.swarmSeeds, isNull);
      expect(swarm.swarmPeers, 5);
      expect(swarm.availability, 0.0);
      expect(host.getTorrentSeeds('a'), 0);
      expect(host.getTorrentPeers('a'), 0);
    });

    test('an all-zero live tick falls back to the last snapshot', () {
      final prev = TorrentService.bridgeCompatible;
      TorrentService.bridgeCompatible = true;
      addTearDown(() => TorrentService.bridgeCompatible = prev);
      host.tasks.add(_torrent('swarmtask'));
      host.torrentIds['swarmtask'] = 7;
      host.stats[7] = _stat(7, numSeeds: 5, numPeers: 6);
      final first = host.getTorrentSwarm('swarmtask');
      expect(first.connectedSeeds, 5);
      // Now an all-zero tick (no swarm totals, no availability).
      host.stats[7] = _stat(7,
          numSeeds: 0,
          numPeers: 0,
          distributedCopies: 0);
      final second = host.getTorrentSwarm('swarmtask');
      expect(second.connectedSeeds, 5);
      host.forgetTorrentSwarm('swarmtask');
      expect(host.getTorrentSwarm('swarmtask').isEmpty, isTrue);
    });

    test('no stats returns empty', () {
      final prev = TorrentService.bridgeCompatible;
      TorrentService.bridgeCompatible = true;
      addTearDown(() => TorrentService.bridgeCompatible = prev);
      host.tasks.add(_torrent('nostats'));
      expect(host.getTorrentSwarm('nostats').isEmpty, isTrue);
    });
  });

  group('getTorrentUploadSpeed', () {
    test('missing task returns zero', () {
      expect(host.getTorrentUploadSpeed('nope'), 0.0);
    });

    test('completed non-seeding task returns zero', () {
      host.tasks.add(_torrent('a', status: DownloadStatus.completed));
      expect(host.getTorrentUploadSpeed('a'), 0.0);
    });

    test('returns live upload rate', () {
      host.tasks.add(_torrent('a', status: DownloadStatus.completed,
          seedingEnabled: true));
      host.torrentIds['a'] = 2;
      host.stats[2] = _stat(2, uploadRate: 1234);
      expect(host.getTorrentUploadSpeed('a'), 1234.0);
    });

    test('returns zero when no stats', () {
      host.tasks.add(_torrent('a', status: DownloadStatus.completed,
          seedingEnabled: true));
      host.torrentIds['a'] = 3;
      expect(host.getTorrentUploadSpeed('a'), 0.0);
    });
  });

  group('getSeedingSummary', () {
    test('empty for unknown task', () {
      expect(host.getSeedingSummary('nope'), '');
    });

    test('includes ratio and seeded time', () {
      host.tasks.add(_torrent('a',
          status: DownloadStatus.completed,
          seedingEnabled: true,
          completedAt: DateTime.now().subtract(const Duration(hours: 2))));
      host.torrentIds['a'] = 4;
      host.stats[4] = _stat(4,
          totalPayloadUpload: 200, totalPayloadDownload: 100);
      final summary = host.getSeedingSummary('a');
      expect(summary, contains('Ratio 2.00'));
      expect(summary, contains('seeded'));
    });

    test('uses task bytes when no stats', () {
      host.tasks.add(_torrent('a',
          status: DownloadStatus.completed,
          seedingEnabled: true,
          downloadedBytes: 10,
          completedAt: DateTime.now()));
      host.torrentIds['a'] = 5;
      expect(host.getSeedingSummary('a'), contains('Ratio 0.00'));
    });
  });

  group('markTorrentFilesCompleted', () {
    test('marks selected complete and unselected zero', () {
      final result = host.markTorrentFilesCompleted([
        {'name': 'a', 'length': 100, 'selected': true},
        {'name': 'b', 'length': 200, 'selected': false},
      ]);
      expect(result[0]['downloadedBytes'], 100);
      expect(result[0]['isComplete'], isTrue);
      expect(result[1]['downloadedBytes'], 0);
      expect(result[1]['isComplete'], isFalse);
    });
  });

  group('getTorrentFileActualBytes', () {
    test('missing task returns empty', () async {
      expect(await host.getTorrentFileActualBytes('nope'), isEmpty);
    });

    test('null files returns empty', () async {
      host.tasks.add(_torrent('a'));
      expect(await host.getTorrentFileActualBytes('a'), isEmpty);
    });

    test('no torrent id maps stored downloadedBytes', () async {
      host.tasks.add(_torrent('a', torrentFiles: [
        {'name': 'f', 'downloadedBytes': 7},
      ]));
      expect(await host.getTorrentFileActualBytes('a'), [7]);
    });

    test('with torrent id returns engine files', () async {
      host.tasks.add(_torrent('a', torrentFiles: [
        {'name': 'f', 'downloadedBytes': 7},
      ]));
      host.torrentIds['a'] = 99;
      expect(await host.getTorrentFileActualBytes('a'), isEmpty);
    });
  });

  group('updateSeedingSpeeds', () {
    test('updates speed for seeding torrents', () {
      host.tasks.add(_torrent('a',
          status: DownloadStatus.completed, seedingEnabled: true));
      host.torrentIds['a'] = 10;
      host.stats[10] = _stat(10, uploadRate: 512);
      expect(host.updateSeedingSpeeds(), isTrue);
      expect(host.tasks.first.speed, 512.0);
    });

    test('clears stale speed on completed non-torrents', () {
      final t = _torrent('a', status: DownloadStatus.completed, speed: 100);
      host.tasks.add(t);
      host.torrentIds.remove('a');
      final changed = host.updateSeedingSpeeds();
      expect(changed, isTrue);
      expect(host.tasks.first.speed, 0.0);
    });

    test('does not stop seeding when native max seeding time is unset', () {
      settings.maxSeedingTimeMinutes = 1;
      host.tasks.add(_torrent('a',
          status: DownloadStatus.completed,
          seedingEnabled: true,
          completedAt: DateTime.now().subtract(const Duration(hours: 2))));
      host.torrentIds['a'] = 11;
      host.stats[11] = _stat(11);
      expect(host.updateSeedingSpeeds(), isTrue);
      expect(host.filteredDirty, isFalse);
    });
  });

  group('updateTaskSeeding', () {
    test('missing task is a no-op', () async {
      await host.updateTaskSeeding('nope', enabled: false);
      expect(db.saved, isEmpty);
    });

    test('disabling snaps bytes to fileSize', () async {
      host.tasks.add(_torrent('a',
          status: DownloadStatus.completed,
          seedingEnabled: true,
          fileSize: 500,
          downloadedBytes: 100));
      await host.updateTaskSeeding('a', enabled: false);
      expect(host.tasks.first.downloadedBytes, 500);
      expect(host.notifyCount, 1);
      expect(host.widgetTimerCount, 1);
    });

    test('enabling a torrent with a known id resumes it', () async {
      host.tasks.add(_torrent('a',
          status: DownloadStatus.paused, seedingEnabled: false));
      host.torrentIds['a'] = 12;
      await host.updateTaskSeeding('a', enabled: true);
      expect(host.tasks.first.seedingEnabled, isTrue);
      expect(db.saved, isNotEmpty);
    });
  });

  group('updateTorrentTaskFiles', () {
    test('missing task is a no-op', () async {
      await host.updateTorrentTaskFiles('nope', []);
      expect(db.saved, isEmpty);
    });

    test('recomputes selected size and downloaded bytes', () async {
      host.tasks.add(_torrent('a', torrentFiles: [
        {'name': 'f1', 'length': 100, 'selected': true, 'downloadedBytes': 10},
        {'name': 'f2', 'length': 200, 'selected': false, 'downloadedBytes': 20},
      ]));
      await host.updateTorrentTaskFiles('a', [
        {'name': 'f1', 'length': 100, 'selected': true, 'downloadedBytes': 10},
        {'name': 'f2', 'length': 200, 'selected': false, 'downloadedBytes': 20},
      ]);
      expect(host.tasks.first.fileSize, 100);
      expect(host.tasks.first.downloadedBytes, 10);
      expect(host.notifyCount, 1);
    });

    test('completed task becomes paused when selected bytes incomplete', () async {
      host.tasks.add(_torrent('a',
          status: DownloadStatus.completed,
          torrentFiles: [
            {'name': 'f1', 'length': 100, 'selected': true, 'downloadedBytes': 0},
          ]));
      await host.updateTorrentTaskFiles('a', [
        {'name': 'f1', 'length': 100, 'selected': true, 'downloadedBytes': 0},
      ]);
      expect(host.tasks.first.status, DownloadStatus.paused);
    });

    test('sets priority on the live engine when id present', () async {
      host.tasks.add(_torrent('a', torrentFiles: [
        {'name': 'f1', 'length': 100, 'selected': true, 'priority': 7},
      ]));
      host.torrentIds['a'] = 14;
      await host.updateTorrentTaskFiles('a', [
        {'name': 'f1', 'length': 100, 'selected': true, 'priority': 7},
      ]);
      expect(host.tasks.first.torrentFiles!.first['lastFileSyncMs'], isNotNull);
    });
  });

  group('checkTorrentRatioLimits', () {
    test('stops seeding when ratio policy exceeded', () async {
      settings.shareRatioLimit = 1.0;
      host.tasks.add(_torrent('a',
          status: DownloadStatus.completed,
          seedingEnabled: true,
          completedAt: DateTime.now()));
      host.torrentIds['a'] = 15;
      host.stats[15] = _stat(15,
          totalPayloadUpload: 1000, totalPayloadDownload: 100, progress: 1.0);
      host.checkTorrentRatioLimits();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(host.tasks.first.seedingEnabled, isFalse);
    });

    test('ignores non-seeding and statless tasks', () {
      host.tasks.add(_torrent('a',
          status: DownloadStatus.completed, seedingEnabled: true));
      host.checkTorrentRatioLimits();
      expect(host.tasks.first.seedingEnabled, isTrue);
    });
  });

  group('enforceTorrentQueue', () {
    test('returns early when queueTorrents disabled', () {
      settings.queueTorrents = false;
      host.tasks.add(_torrent('a'));
      host.enforceTorrentQueue();
      expect(host.notifyCount, 0);
    });

    test('pauses torrents beyond maxActiveDownloads', () async {
      settings.queueTorrents = true;
      settings.maxActiveDownloads = 1;
      host.tasks.add(_torrent('a'));
      host.tasks.add(_torrent('b'));
      host.torrentIds['a'] = 20;
      host.torrentIds['b'] = 21;
      host.enforceTorrentQueue();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final b = host.tasks.firstWhere((t) => t.id == 'b');
      expect(b.status, DownloadStatus.paused);
    });
  });

  group('web seeds', () {
    test('add/get/remove delegate to the service', () {
      host.addWebSeed('http://seed', 1);
      expect(host.getWebSeeds(1), ['http://seed']);
      host.removeWebSeed('http://seed', 1);
      expect(host.getWebSeeds(1), isEmpty);
    });
  });

  group('startSeedingTorrent', () {
    test('removes a stale id and fails cleanly when add is rejected',
        () async {
      final task = _torrent('a',
          status: DownloadStatus.completed, seedingEnabled: true);
      host.tasks.add(task);
      host.torrentIds['a'] = 30;
      await host.startSeedingTorrent(task);
      // Native add rejected (-1); the failure path surfaces a status message.
      expect(host.tasks.first.statusMessage, 'Seeding resume failed');
      expect(db.saved, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('magnet rejected path preserves task without crashing', () async {
      final task = _torrent('b');
      host.tasks.add(task);
      await host.startSeedingTorrent(task);
      expect(db.saved, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('proxy and ssl settings', () {
    test('applyProxySettings persists and notifies', () async {
      await host.applyProxySettings(
        host: '127.0.0.1',
        port: 8080,
        type: ProxyType.socks5,
      );
      expect(host.notifyCount, 1);
    });

    test('applySslSettings persists and notifies', () async {
      await host.applySslSettings(certPath: '/c.pem', privateKeyPath: '/k.pem');
      expect(host.notifyCount, 1);
    });
  });
}
