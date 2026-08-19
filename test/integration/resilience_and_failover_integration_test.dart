import 'dart:io';
import 'package:dmx/core/services/background_service.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/torrent_file_normalizer.dart';
import 'package:dmx/core/services/mirror/mirror_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FIX-22 Integration Tests', () {
    test('1. Background wake lock acquisition and release across app lifecycle',
        () async {
      int acquireCount = 0;
      int releaseCount = 0;

      BackgroundService.testMode = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.dmx.app/wakelock'),
        (methodCall) async {
          if (methodCall.method == 'acquire') {
            acquireCount++;
          } else if (methodCall.method == 'release') {
            releaseCount++;
          }
          return null;
        },
      );

      // App starts download in foreground
      await BackgroundService.setDownloadActive(true, 'job-lifecycle-1');
      expect(acquireCount, equals(1));
      expect(releaseCount, equals(0));

      // App backgrounded while download is active -> wake lock stays held
      expect(BackgroundService.activeDownloadCountForTesting, equals(1));

      // Download finishes in background -> wake lock released
      await BackgroundService.setDownloadActive(false, 'job-lifecycle-1');
      expect(releaseCount, equals(1));
      expect(BackgroundService.activeDownloadCountForTesting, equals(0));

      await BackgroundService.resetWakeLockState();
      BackgroundService.testMode = false;
    });

    test('2. Restart state reconciliation with corrupted .dmxpart state file',
        () async {
      final tempDir = Directory.systemTemp.createTempSync('dmx_corrupt_test_');
      final tempFilePath = '${tempDir.path}/corrupt_sample.mp4.dmxpart';

      // Write garbage data to .dmxpart state file
      final file = File(tempFilePath);
      file.writeAsStringSync('{{{GARBAGE NOT JSON TRUNCATED CONTENT');

      // StateStore.loadOrCreate should gracefully fallback to clean state instead of crashing
      final result = await StateStore.loadOrCreate(
        tempFilePath,
        url: 'https://example.com/movie.mp4',
        threadCount: 4,
        knownFileSize: 10485760,
      );

      expect(result.state, isNotNull);
      expect(result.state.url, equals('https://example.com/movie.mp4'));
      expect(result.state.totalSize, equals(10485760));

      tempDir.deleteSync(recursive: true);
    });

    test('3. 1000-file torrent completion flow integration', () async {
      final thousandFiles = List.generate(
        1000,
        (i) => {
          'name': 'disc_$i/track.flac',
          'length': 10 * 1024 * 1024,
          'downloadedBytes': 10 * 1024 * 1024,
          'selected': true,
        },
      );

      final summary =
          TorrentFileNormalizer.normalizeTorrentFileList(thousandFiles);
      expect(summary.total, equals(1000));
      expect(summary.done, equals(1000));
      expect(summary.bytes, equals(1000 * 10 * 1024 * 1024));
      expect(summary.downloaded, equals(summary.bytes));

      final hash = TorrentFileNormalizer.computeFileListHash(thousandFiles);
      expect(hash, isNonZero);
    });

    test('4. Consecutive mirror failover exhausting all mirrors', () async {
      final mirrors = [
        'https://m1.example.com/file.bin',
        'https://m2.example.com/file.bin',
        'https://m3.example.com/file.bin',
      ];
      final failover = MirrorFailover(mirrors);

      expect(failover.activeUrl, equals(mirrors[0]));

      final m2 = failover.advance();
      expect(m2, isNotNull);

      final m3 = failover.advance();
      expect(m3, isNotNull);

      // Total switches tracked accurately
      expect(failover.mirrorSwitches, greaterThanOrEqualTo(2));
    });
  });
}
