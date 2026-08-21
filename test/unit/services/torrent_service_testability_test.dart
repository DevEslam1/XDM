import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:dmx/features/downloads/services/torrent_session_manager.dart';
import 'package:flutter_test/flutter_test.dart';

class MockTorrentService extends TorrentServiceStub {
  bool pauseCalled = false;
  bool resumeCalled = false;
  int? removedId;
  final Map<int, bool> aliveMap = {};

  @override
  bool isTorrentAlive(int id) => aliveMap[id] ?? true;

  @override
  Future<void> pauseTorrent(int id) async {
    pauseCalled = true;
    aliveMap[id] = false;
  }

  @override
  void resumeTorrent(int id) {
    resumeCalled = true;
    aliveMap[id] = true;
  }

  @override
  void removeTorrent(int id,
      {bool deleteFiles = false, bool deleteResumeData = false}) {
    removedId = id;
    aliveMap.remove(id);
  }
}

void main() {
  group('TorrentService Testability (Fix 4)', () {
    test('TorrentServiceStub satisfies ITorrentService contract', () async {
      final ITorrentService stub = TorrentServiceStub();
      expect(stub.isSupported, isFalse);
      expect(stub.isInitialized, isFalse);
      await stub.ready;
      expect(stub.isAvailable.value, isFalse);
      expect(stub.activeTorrentIds, isEmpty);
      expect(stub.progressFor(1), 0.0);
      expect(stub.addMagnet('magnet:?xt=urn:btih:...', '/tmp'), -1);
      expect(stub.addTorrentFile('/path/to.torrent', '/tmp'), -1);
      expect(stub.getFiles(1), isEmpty);
    });

    test('TorrentDownloadHandler accepts injected ITorrentService', () {
      final mock = MockTorrentService();
      final handler = TorrentDownloadHandler(torrentService: mock);
      expect(handler.activeTorrentIds, isEmpty);
    });

    test('TorrentSessionManager uses injected ITorrentService', () async {
      final mock = MockTorrentService();
      final sessionManager = TorrentSessionManager(torrentService: mock);

      sessionManager.registerTorrentId('task-1', 42);
      expect(sessionManager.getTorrentId('task-1'), 42);
      expect(sessionManager.isTorrentAlive('task-1'), isTrue);

      await sessionManager.pauseTorrent('task-1');
      expect(mock.pauseCalled, isTrue);

      sessionManager.removeTorrent(42);
      expect(mock.removedId, 42);
      expect(sessionManager.getTorrentId('task-1'), isNull);
    });
  });
}
