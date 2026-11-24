import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTorrentNative native;

  setUp(() {
    native = FakeTorrentNative();
  });

  List<NativeFileInfo> files(int count) => List.generate(
        count,
        (i) => NativeFileInfo(
          index: i,
          name: 'file$i.bin',
          path: '/downloads/file$i.bin',
          size: 1000 * (i + 1),
          isStreamable: false,
        ),
      );

  group('FakeTorrentNative identity and capabilities', () {
    test('defaults', () {
      expect(native.isInitialized, isTrue);
      expect(native.libraryVersion, 'libtorrent/2.1.1-fake');
      expect(native.isBridgeCompatible, isTrue);
      expect(native.bridgeDiagnostics, isNull);
      expect(native.forceRecheckSupported, isTrue);
    });

    test('scriptable knobs override defaults', () {
      native.libraryVersion = 'custom';
      native.fakeBridgeCompatible = false;
      native.fakeBridgeDiagnostics = 'drift';
      native.capabilities = const TorrentNativeCapabilities.all();
      expect(native.libraryVersion, 'custom');
      expect(native.isBridgeCompatible, isFalse);
      expect(native.bridgeDiagnostics, 'drift');
      expect(native.capabilities.fileProgress, isTrue);
      expect(native.forceRecheckSupported, isTrue);
    });

    test('init resets the initialized flag', () async {
      await native.dispose();
      expect(native.isInitialized, isFalse);
      await native.init();
      expect(native.isInitialized, isTrue);
    });
  });

  group('FakeTorrentNative lifecycle', () {
    test('addMagnet assigns monotonic ids and seeds status', () {
      final id1 = native.addMagnet('magnet:?xt=urn:btih:a', '/tmp');
      final id2 = native.addMagnet('magnet:?xt=urn:btih:b', '/tmp');
      expect(id1, 1);
      expect(id2, 2);
      expect(native.getTorrentStatus(id1)!.hasMetadata, isFalse);
      expect(native.getAllTorrentStatuses().length, 2);
    });

    test('addTorrentFile initializes a plausible wanted size', () {
      final id = native.addTorrentFile('/tmp/a.torrent', '/tmp');
      final status = native.getTorrentStatus(id)!;
      expect(status.totalWanted, greaterThan(0));
      expect(status.hasMetadata, isTrue);
    });

    test('addMagnet accepts resume data', () {
      final id = native.addMagnet(
        'magnet:?xt=urn:btih:a',
        '/tmp',
        resumeData: const [1, 2, 3],
      );
      expect(native.getTorrentStatus(id), isNotNull);
    });

    test('removeTorrent clears all associated state', () {
      final id = native.addTorrentFile('/tmp/a.torrent', '/tmp');
      native.addTracker(id, 'udp://tracker');
      native.addWebSeed(id, 'https://seed');
      native.removeTorrent(id);
      expect(native.getTorrentStatus(id), isNull);
      expect(native.getFiles(id), isEmpty);
      expect(native.getTrackers(id), isEmpty);
      expect(native.getWebSeeds(id), isEmpty);
    });
  });

  group('FakeTorrentNative status updates', () {
    test('seedTorrent and simulateProgress update aggregate progress', () {
      native.seedTorrent(id: 5, name: 't', files: files(2));
      native.simulateProgress(id: 5, perFileDownloadedBytes: [1000, 2000]);

      final status = native.getTorrentStatus(5)!;
      expect(status.progress, greaterThan(0));
      expect(status.totalDone, 3000);
      expect(status.fileProgress, [1000, 2000]);
    });

    test('simulateProgress is a no-op for an unknown torrent', () {
      native.simulateProgress(id: 99, perFileDownloadedBytes: [1]);
      expect(native.getTorrentStatus(99), isNull);
    });

    test('setFilePriorities recomputes wanted totals', () {
      native.seedTorrent(id: 6, name: 't', files: files(2));
      native.setFilePriorities(6, const [0, 4]);
      final status = native.getTorrentStatus(6)!;
      expect(status.totalWanted, 2000);
      expect(native.getFilePriorities(6), [0, 4]);
    });

    test('recheckTorrent resets progress', () {
      native.seedTorrent(id: 7, name: 't', files: files(1));
      native.simulateProgress(id: 7, perFileDownloadedBytes: [1000]);
      native.recheckTorrent(7);
      final status = native.getTorrentStatus(7)!;
      expect(status.progress, 0.0);
      expect(status.stateLabel, 'Checking files');
    });

    test('getFileProgress reflects the simulated bytes', () {
      native.seedTorrent(id: 8, name: 't', files: files(1));
      native.simulateProgress(id: 8, perFileDownloadedBytes: [500]);
      expect(native.getFileProgress(8), [500]);
    });
  });

  group('FakeTorrentNative pause / resume', () {
    test('graceful pause saves resume data and marks paused', () async {
      native.seedTorrent(id: 9, name: 't', files: files(1));
      await native.pauseTorrent(9);
      expect(native.getTorrentStatus(9)!.isPaused, isTrue);
      expect(native.saveResumeDataCallCount, 1);
    });

    test('non-graceful pause skips the resume save', () async {
      native.seedTorrent(id: 10, name: 't', files: files(1));
      await native.pauseTorrent(10, graceful: false);
      expect(native.getTorrentStatus(10)!.isPaused, isTrue);
      expect(native.saveResumeDataCallCount, 0);
    });

    test('graceful pause timeout leaves the torrent running', () async {
      native.simulateGracefulPauseTimeout = true;
      native.seedTorrent(id: 11, name: 't', files: files(1));
      await native.pauseTorrent(11);
      expect(native.getTorrentStatus(11)!.isPaused, isFalse);
    });

    test('pause on an unknown torrent is a no-op', () async {
      await native.pauseTorrent(404);
      expect(native.getTorrentStatus(404), isNull);
    });

    test('graceful pause honours the configured delay', () async {
      native.gracefulPauseDelay = const Duration(milliseconds: 1);
      native.seedTorrent(id: 12, name: 't', files: files(1));
      await native.pauseTorrent(12);
      expect(native.getTorrentStatus(12)!.isPaused, isTrue);
    });

    test('graceful pause records telemetry when resume data is missing',
        () async {
      final events = <String>[];
      final nullResume = _NullResumeNative()
        ..onTelemetryAlert = (e, {taskId, details}) => events.add(e);
      nullResume.seedTorrent(id: 14, name: 't', files: files(1));
      await nullResume.pauseTorrent(14);
      expect(events, contains('resume_data_missing'));
    });

    test('graceful pause records telemetry when resume save throws', () async {
      final events = <String>[];
      final throwResume = _ThrowResumeNative()
        ..onTelemetryAlert = (e, {taskId, details}) => events.add(e);
      throwResume.seedTorrent(id: 15, name: 't', files: files(1));
      await throwResume.pauseTorrent(15);
      expect(events, contains('resume_data_missing'));
    });

    test('resume clears the paused flag', () async {
      native.seedTorrent(id: 13, name: 't', files: files(1));
      await native.pauseTorrent(13);
      await native.resumeTorrent(13);
      expect(native.getTorrentStatus(13)!.isPaused, isFalse);
      expect(native.getTorrentStatus(13)!.stateLabel, 'Downloading');
    });

    test('resume on an unknown torrent is a no-op', () async {
      await native.resumeTorrent(404);
    });
  });

  group('FakeTorrentNative resume data', () {
    test('saveResumeData returns a blob and increments the counter', () async {
      final blob = await native.saveResumeData(1);
      expect(blob, isNotNull);
      expect(blob, isNotEmpty);
      expect(native.saveResumeDataCallCount, 1);
    });

    test('loadResumeData stores data, unless a failure is simulated', () {
      expect(native.loadResumeData(1, const [1, 2]), isTrue);
      native.simulateResumeLoadFailure = true;
      expect(native.loadResumeData(1, const [3, 4]), isFalse);
    });
  });

  group('FakeTorrentNative trackers, seeds and config', () {
    test('tracker add/remove round-trips', () {
      native.addTracker(1, 'udp://tracker');
      expect(native.getTrackers(1).length, 1);
      native.removeTracker(1, 'udp://tracker');
      expect(native.getTrackers(1), isEmpty);
    });

    test('web seed add/remove deduplicates', () {
      native.addWebSeed(1, 'https://seed');
      native.addWebSeed(1, 'https://seed');
      expect(native.getWebSeeds(1), ['https://seed']);
      native.removeWebSeed(1, 'https://seed');
      expect(native.getWebSeeds(1), isEmpty);
    });

    test('peers are scriptable', () async {
      native.seedPeers(1, const []);
      expect(await native.getPeers(1), isEmpty);
    });

    test('configureSession captures the last config', () {
      const config = NativeBtConfig(connectionsLimit: 42);
      native.configureSession(config);
      expect(native.lastConfig!.connectionsLimit, 42);
      expect(native.getDefaultConfig(), isA<NativeBtConfig>());
    });

    test('sequential / super seeding toggles do not throw', () {
      native.setSequentialDownload(1, true);
      native.setSequentialDownload(1, false);
      native.setSuperSeeding(1, true);
      native.setSuperSeeding(1, false);
      native.setPieceDeadline(1, 0, 100);
      native.setDownloadLimit(1);
      native.setUploadLimit(1);
    });

    test('misc native operations return scripted values', () async {
      expect(
        await native.createTorrent(
          sourcePath: '/a',
          outputPath: '/b',
          trackers: const [],
        ),
        '/b',
      );
      expect(await native.loadIpFilter('/f'), isTrue);
      await native.setProxy(host: 'h', port: 1, type: 0);
      await native.setSslCertificate(certPath: '/c', privateKeyPath: '/k');
      native.announceNow(1);
    });
  });

  group('FakeTorrentNative telemetry and streams', () {
    test('emitAlert and emitStatuses reach subscribers', () async {
      final alerts = <NativeAlertEvent>[];
      final statuses = <Map<int, NativeTorrentStatus>>[];
      final aSub = native.alertStream.listen(alerts.add);
      final sSub = native.statusStream.listen(statuses.add);
      addTearDown(aSub.cancel);
      addTearDown(sSub.cancel);

      native.emitAlert(NativeAlertEvent(
        type: TorrentAlertType.statusTick,
        alertCode: 0,
        torrentId: 1,
        message: 'tick',
        timestamp: DateTime.now(),
      ));
      native.emitStatuses({});
      await Future<void>.delayed(Duration.zero);

      expect(alerts.length, 1);
      expect(statuses, isNotEmpty);
    });

    test('onTelemetryAlert receives the resume-data-missing event', () async {
      final events = <String>[];
      native.onTelemetryAlert = (event, {taskId, details}) => events.add(event);
      native.simulateGracefulPauseTimeout = true;
      native.seedTorrent(id: 1, name: 't', files: files(1));

      await native.pauseTorrent(1);
      expect(events, contains('resume_data_missing'));
    });

    test('dispose closes the streams and clears state', () async {
      native.seedTorrent(id: 1, name: 't', files: files(1));
      await native.dispose();
      expect(native.isInitialized, isFalse);
      expect(native.getTorrentStatus(1), isNull);
      // Emitting after close must not throw.
      native.emitAlert(NativeAlertEvent(
        type: TorrentAlertType.statusTick,
        alertCode: 0,
        torrentId: 1,
        message: 'x',
        timestamp: DateTime.now(),
      ));
    });
  });
}

class _NullResumeNative extends FakeTorrentNative {
  @override
  Future<List<int>?> saveResumeData(
    int id, {
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      null;
}

class _ThrowResumeNative extends FakeTorrentNative {
  @override
  Future<List<int>?> saveResumeData(
    int id, {
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      throw StateError('resume save failed');
}
