import 'package:dmx/core/services/remote_api_service.dart';
import 'package:dmx/core/services/torrent_service_stub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Task 6: Feature Availability Safety Suite', () {
    test('TorrentService stub reports unsupported and unavailable', () {
      expect(TorrentService.isSupported, isFalse,
          reason: 'Stubbed torrent service must report unsupported');
      expect(TorrentService.isAvailable.value, isFalse,
          reason: 'Stubbed torrent service availability notifier must be false');
      expect(TorrentService.addMagnet('magnet:?xt=urn:btih:012345', '/tmp'), equals(-1));
      expect(TorrentService.activeTorrentIds, isEmpty);
    });

    test('RemoteApiService is disabled by default and starts no server', () async {
      expect(RemoteApiService.enabled, isFalse,
          reason: 'Remote API server must be disabled by default for zero attack surface');

      // Call start with dummy callbacks
      await RemoteApiService.start(
        getTasks: () async => [],
        pauseTask: (id) async {},
        resumeTask: (id) async {},
        deleteTask: (id) async {},
      );

      // Server should not be created
      expect(RemoteApiService.enabled, isFalse);
    });
  });
}
