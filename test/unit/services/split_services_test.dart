import 'package:dmx/features/downloads/services/torrent_session_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TorrentSessionManager Tests', () {
    test('registers and queries torrent IDs', () {
      final manager = TorrentSessionManager();
      manager.registerTorrentId('t-1', 42);

      expect(manager.getTorrentId('t-1'), 42);
      manager.unregisterTorrent('t-1');
      expect(manager.getTorrentId('t-1'), isNull);
    });
  });
}
