import 'package:dmx/core/services/torrent/libtorrent_native_impl.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibtorrentNativeImpl native;

  setUp(() {
    native = LibtorrentNativeImpl();
  });

  tearDown(() async {
    await native.dispose();
  });

  group('LibtorrentNativeImpl metadata', () {
    test('reports the libtorrent_dart 1.2.0 (2.0.11) bridge', () {
      expect(native.bridgeDiagnostics, isNotNull);
      expect(native.bridgeDiagnostics, contains('libtorrent_dart 1.2.0'));
      expect(native.isBridgeCompatible, isTrue);
      expect(native.capabilities.resumeData, isTrue);
      expect(native.capabilities.fileProgress, isTrue);
      expect(native.capabilities.filePriorities, isTrue);
      expect(native.capabilities.trackers, isTrue);
      expect(native.capabilities.createTorrent, isTrue);
      expect(native.capabilities.webSeeds, isTrue);
      expect(native.capabilities.proxy, isTrue);
      expect(native.capabilities.ipFilter, isFalse);
      expect(native.capabilities.ssl, isFalse);
      expect(native.forceRecheckSupported, isTrue);
    });

    test('reports initialization state and version', () {
      if (!native.isInitialized) {
        expect(native.libraryVersion, 'unknown');
      } else {
        expect(native.libraryVersion, isNotEmpty);
      }
    });

    test('exposes broadcast alert and status streams', () {
      expect(native.alertStream.isBroadcast, isTrue);
      expect(native.statusStream.isBroadcast, isTrue);
    });
  });

  group('LibtorrentNativeImpl unsupported surface', () {
    test('per-file progress and peers are unavailable', () async {
      expect(native.getFileProgress(1), isEmpty);
      expect(await native.getPeers(1), isEmpty);
    });

    test('resume data is unavailable', () async {
      expect(await native.saveResumeData(1), isNull);
      expect(native.loadResumeData(1, const [1, 2]), isFalse);
    });

    test('trackers and web seeds are unavailable', () {
      expect(native.getTrackers(1), isEmpty);
      native.addTracker(1, 'udp://t');
      native.removeTracker(1, 'udp://t');
      native.announceNow(1);
      expect(native.getWebSeeds(1), isEmpty);
      native.addWebSeed(1, 'https://s');
      native.removeWebSeed(1, 'https://s');
    });

    test('torrent creation and ip filter loading are unavailable', () async {
      expect(
        await native.createTorrent(
          sourcePath: '/a',
          outputPath: '/b',
          trackers: const [],
        ),
        isNull,
      );
      expect(await native.loadIpFilter('/f'), isFalse);
    });

    test('session toggles are no-ops', () async {
      native.setSequentialDownload(1, true);
      native.setSuperSeeding(1, true);
      native.setPieceDeadline(1, 0, 100);
      await native.setProxy(host: 'h', port: 1, type: 0);
      await native.setSslCertificate(certPath: '/c', privateKeyPath: '/k');
    });

    test('negative torrent ids short-circuit', () async {
      native.removeTorrent(-1);
      await native.pauseTorrent(-1);
      await native.resumeTorrent(-1);
      native.recheckTorrent(-1);
    });
  });

  group('LibtorrentNativeImpl dispose', () {
    test('closes its streams and can be called twice', () async {
      await native.dispose();
      expect(await native.alertStream.isEmpty, isTrue);
      expect(await native.statusStream.isEmpty, isTrue);
    });
  });
}
