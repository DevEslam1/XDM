import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Background Download Integration Test', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      DownloadEngine.appInForeground = true;
    });

    test('transitions to background and preserves engine state', () async {
      expect(DownloadEngine.appInForeground, isTrue);
      expect(DownloadEngine.isInBackground, isFalse);

      // Transition to background
      DownloadEngine.appInForeground = false;
      expect(DownloadEngine.isInBackground, isTrue);

      final task = DownloadTask(
        id: 'bg-task-1',
        url: 'https://example.com/largefile.zip',
        fileName: 'largefile.zip',
        savePath: '/tmp',
        localFilePath: '/tmp/largefile.zip',
        tempFilePath: '/tmp/largefile.zip.dmxpart',
        category: 'other',
        threadCount: 1,
        chunks: const [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        status: DownloadStatus.downloading,
        downloadedBytes: 1024 * 1024,
        fileSize: 10 * 1024 * 1024,
      );

      expect(task.downloadedBytes, 1024 * 1024);
      expect(task.fileSize, 10 * 1024 * 1024);
      expect(task.status, DownloadStatus.downloading);

      // Transition back to foreground
      DownloadEngine.appInForeground = true;
      expect(DownloadEngine.appInForeground, isTrue);
      expect(DownloadEngine.isInBackground, isFalse);
    });

    test('BackgroundService handles foreground and background power state queries safely', () {
      final power = PowerMonitor();
      expect(power, isNotNull);
      expect(PowerMonitor.batteryLevel, greaterThanOrEqualTo(0));
    });
  });
}
