
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/fake_torrent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeITorrentService service;
  late TorrentDownloadHandler handler;

  setUp(() {
    TorrentSubscriptionRegistry.instance.clear();
    service = FakeITorrentService();
    handler = TorrentDownloadHandler(torrentService: service);
  });

  tearDown(() {
    handler.dispose();
    TorrentSubscriptionRegistry.instance.clear();
  });

  group('haltTorrent', () {
    test('force-stops a metadata-less torrent immediately', () async {
      service.addMagnet('magnet:?xt=urn:btih:a', '/tmp');
      final id = service.activeTorrentIds.first;

      await handler.haltTorrent(id);

      expect(service.forceStoppedTorrents, contains(id));
      expect(handler.activeTorrentIds, isNot(contains(id)));
    });

    test('returns early for a torrent the service no longer tracks', () async {
      await handler.haltTorrent(999);
      expect(handler.activeTorrentIds, isEmpty);
    });

    test('confirms a graceful pause when stats report paused', () async {
      service.seedTorrent(
        id: 42,
        name: 'seed.bin',
        totalWanted: 1000,
        hasMetadata: true,
      );
      await service.pauseTorrent(42);

      await handler.haltTorrent(42);

      expect(handler.activeTorrentIds, isNot(contains(42)));
      expect(service.forceStoppedTorrents, isNot(contains(42)));
    });
  });

  group('lifecycle', () {
    test('removeActiveTorrent is safe for untracked ids', () {
      expect(() => handler.removeActiveTorrent(7), returnsNormally);
      expect(handler.activeTorrentIds, isNot(contains(7)));
    });

    test('dispose clears runtime state without throwing', () {
      service.seedTorrent(id: 8, name: 'x', totalWanted: 10);
      service.seedTorrent(id: 9, name: 'y', totalWanted: 10);

      expect(handler.dispose, returnsNormally);
      expect(handler.activeTorrentIds, isEmpty);
    });
  });

  group('runtime accessors', () {
    test('cached timestamp/label accessors round-trip', () {
      final now = DateTime(2026, 5, 5);
      handler.lastProgressTick = now;
      handler.lastAccurateSync = now;
      handler.cachedAccurateFiles = [
        {'name': 'a', 'length': 1},
      ];
      handler.lastStateLabel = 'Downloading';

      expect(handler.lastProgressTick, now);
      expect(handler.lastAccurateSync, now);
      expect(handler.cachedAccurateFiles, hasLength(1));
      expect(handler.lastStateLabel, 'Downloading');
    });

    test('runtimeFor and getRuntimeForTesting are null before use', () {
      expect(handler.runtimeFor(123), isNull);
      expect(handler.getRuntimeForTesting(123), isNull);
    });
  });
}
