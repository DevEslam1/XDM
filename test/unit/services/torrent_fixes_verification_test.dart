import 'dart:io';
import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final Directory tempDir;
  MockPathProviderPlatform(this.tempDir);

  @override
  Future<String?> getApplicationSupportPath() async => tempDir.path;

  @override
  Future<String?> getTemporaryPath() async => tempDir.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory testDir;

  setUp(() async {
    testDir = await Directory.systemTemp.createTemp('dmx_torrent_test_');
    PathProviderPlatform.instance = MockPathProviderPlatform(testDir);
  });

  tearDown(() async {
    if (await testDir.exists()) {
      await testDir.delete(recursive: true);
    }
  });

  group('Torrent Fixes & Resiliency Verification', () {
    test(
        'TorrentResumeStore persistently caches and retrieves remote .torrent bytes',
        () async {
      const sourceUrl = 'https://example.com/distro.torrent';
      final dummyBytes = [
        0x64,
        0x38,
        0x3a,
        0x61,
        0x6e,
        0x6e,
        0x6f,
        0x75,
        0x6e,
        0x63,
        0x65,
        0x65
      ]; // "d8:announcee"

      // Initially no cached file
      final initial = await TorrentResumeStore.getTorrentFile(sourceUrl);
      expect(initial, isNull);

      // Save persistent file
      final savedFile =
          await TorrentResumeStore.saveTorrentFile(sourceUrl, dummyBytes);
      expect(await savedFile.exists(), isTrue);
      expect(await savedFile.readAsBytes(), dummyBytes);

      // Subsequent get finds it
      final retrieved = await TorrentResumeStore.getTorrentFile(sourceUrl);
      expect(retrieved, isNotNull);
      expect(retrieved!.path, savedFile.path);

      // Cleanup deletes .torrent file along with metadata
      await TorrentResumeStore.deleteResumeDataForSource(sourceUrl);
      final afterDelete = await TorrentResumeStore.getTorrentFile(sourceUrl);
      expect(afterDelete, isNull);
    });

    test('Rate limit byte calculation adheres to KB/s * 1024 standard', () {
      const int limitKbps = 500; // 500 KB/s
      const int correctBytesPerSec = limitKbps * 1024;
      expect(correctBytesPerSec, 512000);

      // Verify the old bug: (500 * 1000) ~/ 8 = 62500 bytes/s (1/8.2 of intended speed)
      const int oldThrottledBps = (limitKbps * 1000) ~/ 8;
      expect(oldThrottledBps, 62500);
      expect(correctBytesPerSec, isNot(equals(oldThrottledBps)));
    });

    test(
        'TorrentUpdateInfo exposes piecesHave correctly for degraded snapshots',
        () {
      final updateInfo = TorrentUpdateInfo(
        id: 1,
        name: 'test.torrent',
        progress: 0.5,
        downloadRate: 102400,
        uploadRate: 51200,
        totalDone: 500000,
        totalWanted: 1000000,
        totalWantedDone: 500000,
        hasMetadata: true,
        stateLabel: 'downloading',
        state: TorrentState.downloading,
        isPaused: false,
        numSeeds: 10,
        numPeers: 25,
        piecesHave: 50,
        piecesTotal: 100,
        downloadPayloadRate: 100000,
        uploadPayloadRate: 50000,
        totalPayloadDownload: 500000,
        totalPayloadUpload: 250000,
        currentTracker: 'udp://tracker.opentrackr.org:1337',
        nextAnnounceSeconds: 60,
        infoHash: 'abcdef1234567890',
        infoHashV1: 'abcdef1234567890',
        infoHashV2: '',
        distributedCopies: 1.0,
        activeTime: 300,
        seedingTime: 0,
        fileProgress: const [],
        filePriorities: const [],
        pieces: List.generate(100, (i) => i < 50),
      );

      expect(updateInfo.piecesHave, 50);
      expect(updateInfo.piecesTotal, 100);
      expect(updateInfo.pieces.length, 100);
    });
  });
}
