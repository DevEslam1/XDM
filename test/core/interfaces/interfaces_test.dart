import 'dart:async';

import 'package:dmx/core/interfaces/i_connectivity.dart';
import 'package:dmx/core/interfaces/i_download_engine.dart';
import 'package:dmx/core/interfaces/i_task_data_source.dart';
import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_download_engine.dart';
import '../../helpers/test_helpers.dart';

/// Minimal in-memory implementation used to assert the [ITaskDataSource]
/// contract is implementable and behaves as specified.
class _FakeTaskDataSource implements ITaskDataSource {
  final Map<String, DownloadTask> _store = {};
  final StreamController<DownloadTask> _updates =
      StreamController<DownloadTask>.broadcast();

  @override
  Future<List<DownloadTask>> getAll() async => _store.values.toList();

  @override
  Future<DownloadTask?> getById(String id) async => _store[id];

  @override
  Future<void> save(DownloadTask task) async {
    _store[task.id] = task;
    _updates.add(task);
  }

  @override
  Future<void> saveAll(List<DownloadTask> tasks) async {
    for (final task in tasks) {
      _store[task.id] = task;
    }
  }

  @override
  Future<void> delete(String id) async {
    _store.remove(id);
  }

  @override
  Future<void> deleteAll(List<String> ids) async {
    for (final id in ids) {
      _store.remove(id);
    }
  }

  @override
  Stream<DownloadTask> watchTask(String id) =>
      _updates.stream.where((task) => task.id == id);

  Future<void> dispose() => _updates.close();
}

class _FakeConnectivity implements IConnectivity {
  _FakeConnectivity(this.hasConnection);
  @override
  final bool hasConnection;
}

/// Extends the interface so the concrete default getters run, and forwards the
/// abstract surface to [noSuchMethod] since these tests never call it.
class _MinimalTorrentNative extends ITorrentNative {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('IConnectivity', () {
    test('exposes hasConnection through the interface', () {
      final online = _FakeConnectivity(true);
      final offline = _FakeConnectivity(false);
      expect(online.hasConnection, isTrue);
      expect(offline.hasConnection, isFalse);
      expect(online, isA<IConnectivity>());
    });
  });

  group('ITaskDataSource', () {
    late _FakeTaskDataSource source;

    setUp(() => source = _FakeTaskDataSource());
    tearDown(() => source.dispose());

    test('save/getAll/getById/delete round-trip', () async {
      final task = createTestTask(id: 'a');
      await source.save(task);

      expect((await source.getAll()).length, 1);
      expect((await source.getById('a'))?.id, 'a');
      expect(await source.getById('missing'), isNull);

      await source.delete('a');
      expect(await source.getAll(), isEmpty);
    });

    test('saveAll stores every task and deleteAll removes them', () async {
      await source.saveAll([
        createTestTask(id: 'a'),
        createTestTask(id: 'b'),
        createTestTask(id: 'c'),
      ]);
      expect((await source.getAll()).length, 3);

      await source.deleteAll(['a', 'c']);
      final remaining = await source.getAll();
      expect(remaining.length, 1);
      expect(remaining.first.id, 'b');
    });

    test('watchTask emits only matching ids', () async {
      final received = <String>[];
      final sub = source.watchTask('target').listen((t) => received.add(t.id));
      await source.save(createTestTask(id: 'other'));
      await source.save(createTestTask(id: 'target'));
      await Future<void>.delayed(Duration.zero);
      expect(received, ['target']);
      await sub.cancel();
    });
  });

  group('IDownloadEngine', () {
    test('a concrete implementation satisfies the interface contract',
        () async {
      final engine = FakeIDownloadEngine();
      expect(engine, isA<IDownloadEngine>());

      expect(engine.buildTempFilePath('/save', 'file.bin'),
          '/save/file.bin.dmxpart');
      expect(await engine.hasEnoughDiskSpace('/save', 10), isTrue);

      engine.updateSpeedLimit(100, 1);
      engine.forceCancelJob('nope');
      expect(engine.forceCancelledTasks, contains('nope'));

      await engine.close();
    });
  });

  group('ITorrentService', () {
    test('TorrentServiceStub implements the composite and sub-interfaces', () {
      final stub = TorrentServiceStub();
      expect(stub, isA<ITorrentService>());
      expect(stub, isA<ITorrentLifecycle>());
      expect(stub, isA<ITorrentStats>());
      expect(stub, isA<ITorrentResume>());
      expect(stub, isA<ITorrentConfig>());
      expect(stub, isA<ITorrentTrackers>());

      expect(stub.isSupported, isFalse);
      expect(stub.isInitialized, isFalse);
      expect(stub.activeTorrentIds, isEmpty);
      expect(stub.idForSource('anything'), isNull);
      expect(stub.latestStats, isEmpty);
    });
  });

  group('ITorrentNative defaults', () {
    test('default getters are provided by the interface', () {
      final native = _MinimalTorrentNative();
      expect(native.bridgeDiagnostics, isNull);
      expect(native.isBridgeCompatible, isTrue);
      expect(native.capabilities.forceRecheck, isTrue);
      expect(native.forceRecheckSupported, isTrue);
    });

    test('FakeTorrentNative satisfies the contract', () async {
      final fake = FakeTorrentNative();
      expect(fake, isA<ITorrentNative>());
      expect(fake.isInitialized, isTrue);
      expect(fake.libraryVersion, isNotEmpty);
      expect(fake.forceRecheckSupported, isTrue);
      expect(fake.alertStream, isA<Stream<NativeAlertEvent>>());
      expect(fake.statusStream, isA<Stream<Map<int, NativeTorrentStatus>>>());
      await fake.dispose();
    });
  });

  group('TorrentAlertType.fromNativeType', () {
    test('maps known libtorrent alert codes', () {
      expect(
          TorrentAlertType.fromNativeType(16), TorrentAlertType.trackerReply);
      expect(
          TorrentAlertType.fromNativeType(17), TorrentAlertType.trackerError);
      expect(TorrentAlertType.fromNativeType(19),
          TorrentAlertType.fastresumeRejected);
      expect(
          TorrentAlertType.fromNativeType(26), TorrentAlertType.pieceFinished);
      expect(TorrentAlertType.fromNativeType(30),
          TorrentAlertType.saveResumeDataCompleted);
      expect(TorrentAlertType.fromNativeType(31),
          TorrentAlertType.saveResumeDataFailed);
      expect(
          TorrentAlertType.fromNativeType(34), TorrentAlertType.torrentPaused);
      expect(
          TorrentAlertType.fromNativeType(35), TorrentAlertType.torrentResumed);
      expect(TorrentAlertType.fromNativeType(38),
          TorrentAlertType.metadataReceived);
      expect(
          TorrentAlertType.fromNativeType(64), TorrentAlertType.torrentError);
    });

    test('falls back to other for unknown codes', () {
      expect(TorrentAlertType.fromNativeType(999), TorrentAlertType.other);
    });
  });

  group('NativeAlertEvent', () {
    test('toString includes type, id, code, and message', () {
      final event = NativeAlertEvent(
        type: TorrentAlertType.torrentPaused,
        alertCode: 34,
        torrentId: 7,
        message: 'paused',
        timestamp: DateTime(2024),
      );
      final text = event.toString();
      expect(text, contains('torrentPaused'));
      expect(text, contains('id=7'));
      expect(text, contains('code=34'));
      expect(text, contains('msg=paused'));
    });
  });

  group('NativeTorrentStatus.copyWith', () {
    NativeTorrentStatus base() => const NativeTorrentStatus(
          id: 1,
          name: 'n',
          savePath: '/s',
          errorMsg: 'err',
          state: 1,
          stateLabel: 'Downloading',
          progress: 0.1,
          downloadRate: 10,
          uploadRate: 2,
          totalDone: 100,
          totalWanted: 1000,
          totalWantedDone: 100,
          totalUploaded: 5,
          numPeers: 1,
          numSeeds: 1,
          isPaused: false,
          isFinished: false,
          hasMetadata: true,
          queuePosition: 0,
        );

    test('copies every supplied field', () {
      final copy = base().copyWith(
        name: 'n2',
        savePath: '/s2',
        errorMsg: 'e2',
        state: 2,
        stateLabel: 'Seeding',
        progress: 0.9,
        downloadRate: 20,
        uploadRate: 3,
        totalDone: 900,
        totalWanted: 1000,
        totalWantedDone: 900,
        totalUploaded: 50,
        numPeers: 4,
        numSeeds: 5,
        numComplete: 6,
        numIncomplete: 7,
        numPieces: 8,
        piecesDone: 9,
        pieces: const [true],
        isPaused: true,
        isFinished: true,
        hasMetadata: false,
        queuePosition: 2,
        fileProgress: const [1],
        filePriorities: const [4],
        infoHashV1: 'v1',
        infoHashV2: 'v2',
        distributedCopies: 1.5,
        activeTime: 11,
        seedingTime: 12,
      );
      expect(copy.id, 1);
      expect(copy.name, 'n2');
      expect(copy.errorMsg, 'e2');
      expect(copy.stateLabel, 'Seeding');
      expect(copy.progress, 0.9);
      expect(copy.numComplete, 6);
      expect(copy.pieces, const [true]);
      expect(copy.isPaused, isTrue);
      expect(copy.infoHashV2, 'v2');
      expect(copy.distributedCopies, 1.5);
      expect(copy.seedingTime, 12);
    });

    test('clearErrorMsg empties the error while preserving other fields', () {
      final cleared = base().copyWith(clearErrorMsg: true);
      expect(cleared.errorMsg, '');
      expect(cleared.name, 'n');
    });

    test('without arguments returns an equivalent status', () {
      final unchanged = base().copyWith();
      expect(unchanged.name, 'n');
      expect(unchanged.errorMsg, 'err');
    });
  });

  group('NativeBtConfig', () {
    test('defaults match the documented values', () {
      // ignore: prefer_const_constructors (runtime construction exercises the constructor for coverage)
      final config = NativeBtConfig();
      expect(config.cacheSize, 64 * 1024 * 1024);
      expect(config.readerReadAhead, 95);
      expect(config.preloadCache, 50);
      expect(config.connectionsLimit, 200);
      expect(config.torrentDisconnectTimeout, 30);
      expect(config.forceEncrypt, isFalse);
      expect(config.disableTcp, isFalse);
      expect(config.disableUtp, isFalse);
      expect(config.disableUpload, isFalse);
      expect(config.disableDht, isFalse);
      expect(config.disableUpnp, isFalse);
      expect(config.enableIpv6, isFalse);
      expect(config.downloadRateLimit, 0);
      expect(config.uploadRateLimit, 0);
      expect(config.peersListenPort, 0);
      expect(config.responsiveMode, isTrue);
      expect(config.dhtBootstrapNodes.length, 4);
    });

    test('honors explicit overrides', () {
      // ignore: prefer_const_constructors (runtime construction exercises the constructor for coverage)
      final config = NativeBtConfig(
        cacheSize: 1,
        downloadRateLimit: 100,
        uploadRateLimit: 50,
        dhtBootstrapNodes: ['x:1'],
      );
      expect(config.cacheSize, 1);
      expect(config.downloadRateLimit, 100);
      expect(config.uploadRateLimit, 50);
      expect(config.dhtBootstrapNodes, ['x:1']);
    });
  });

  group('TorrentNativeCapabilities', () {
    test('default constructor only enables force-recheck', () {
      // ignore: prefer_const_constructors (runtime construction exercises the constructor for coverage)
      final caps = TorrentNativeCapabilities();
      expect(caps.forceRecheck, isTrue);
      expect(caps.fileProgress, isFalse);
      expect(caps.resumeData, isFalse);
      expect(caps.trackers, isFalse);
      expect(caps.anonymousMode, isFalse);
      expect(caps.perTorrentConnectionLimit, isFalse);
    });

    test('v192 pins the bundled bridge capabilities', () {
      // ignore: prefer_const_constructors (runtime construction exercises the constructor for coverage)
      final caps = TorrentNativeCapabilities.v192();
      expect(caps.forceRecheck, isTrue);
      expect(caps.fileProgress, isFalse);
      expect(caps.filePriorities, isFalse);
      expect(caps.resumeData, isFalse);
      expect(caps.trackers, isFalse);
      expect(caps.reannounce, isFalse);
      expect(caps.createTorrent, isFalse);
      expect(caps.ipFilter, isFalse);
      expect(caps.webSeeds, isFalse);
      expect(caps.proxy, isFalse);
      expect(caps.ssl, isFalse);
    });

    test('v2011 advertises libtorrent_dart 1.2.0 capabilities', () {
      // ignore: prefer_const_constructors
      final caps = TorrentNativeCapabilities.v2011();
      expect(caps.forceRecheck, isTrue);
      expect(caps.fileProgress, isTrue);
      expect(caps.filePriorities, isTrue);
      expect(caps.resumeData, isTrue);
      expect(caps.trackers, isTrue);
      expect(caps.reannounce, isTrue);
      expect(caps.createTorrent, isTrue);
      expect(caps.sequentialDownload, isTrue);
      expect(caps.superSeeding, isTrue);
      expect(caps.pieceDeadline, isTrue);
      expect(caps.webSeeds, isTrue);
      expect(caps.proxy, isTrue);
      expect(caps.localPeerDiscovery, isTrue);
      expect(caps.natPmp, isTrue);
      expect(caps.anonymousMode, isTrue);
      expect(caps.perTorrentConnectionLimit, isTrue);
      expect(caps.ipFilter, isFalse);
      expect(caps.ssl, isFalse);
      expect(caps.peerExchange, isFalse);
    });

    test('all advertises every capability', () {
      // ignore: prefer_const_constructors (runtime construction exercises the constructor for coverage)
      final caps = TorrentNativeCapabilities.all();
      expect(caps.fileProgress, isTrue);
      expect(caps.filePriorities, isTrue);
      expect(caps.resumeData, isTrue);
      expect(caps.forceRecheck, isTrue);
      expect(caps.trackers, isTrue);
      expect(caps.reannounce, isTrue);
      expect(caps.createTorrent, isTrue);
      expect(caps.ipFilter, isTrue);
      expect(caps.sequentialDownload, isTrue);
      expect(caps.superSeeding, isTrue);
      expect(caps.pieceDeadline, isTrue);
      expect(caps.webSeeds, isTrue);
      expect(caps.proxy, isTrue);
      expect(caps.ssl, isTrue);
      expect(caps.peerExchange, isTrue);
      expect(caps.localPeerDiscovery, isTrue);
      expect(caps.natPmp, isTrue);
      expect(caps.anonymousMode, isTrue);
      expect(caps.perTorrentConnectionLimit, isTrue);
    });
  });

  group('NativeFileInfo / NativeTrackerInfo', () {
    test('hold their constructed values', () {
      // ignore: prefer_const_constructors (runtime construction exercises the constructor for coverage)
      final file = NativeFileInfo(
        index: 2,
        name: 'a.bin',
        path: '/a.bin',
        size: 100,
        isStreamable: true,
      );
      expect(file.index, 2);
      expect(file.isStreamable, isTrue);

      // ignore: prefer_const_constructors (runtime construction exercises the constructor for coverage)
      final tracker = NativeTrackerInfo(
        url: 'udp://tracker:80',
        tier: 1,
        status: 'working',
        seeds: 3,
        peers: 4,
        message: 'ok',
      );
      expect(tracker.url, 'udp://tracker:80');
      expect(tracker.tier, 1);
      expect(tracker.message, 'ok');
    });
  });
}
