import 'package:dmx/core/services/background_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Wake Lock Release Integration Tests (L12)', () {
    int acquireCount = 0;
    int releaseCount = 0;
    int activeDownloads = 0;

    setUp(() {
      acquireCount = 0;
      releaseCount = 0;
      activeDownloads = 0;

      BackgroundService.testMode = true;
      BackgroundService.setActiveDownloadCountQuery(() => activeDownloads);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.dmx.app/wakelock'),
        (methodCall) async {
          if (methodCall.method == 'acquire') {
            acquireCount++;
            return null;
          } else if (methodCall.method == 'release') {
            releaseCount++;
            return null;
          }
          return null;
        },
      );
    });

    tearDown(() async {
      await BackgroundService.resetWakeLockState();
      BackgroundService.setActiveDownloadCountQuery(null);
      BackgroundService.testMode = false;
      BackgroundService.resetActiveDownloadCountForTesting();
    });

    test(
        'wake-lock is held while active > 0 and released when active drops to 0',
        () async {
      // 1. Start 2 downloads
      activeDownloads = 2;
      await BackgroundService.setDownloadActive(true, 'task-1');
      await BackgroundService.setDownloadActive(true, 'task-2');
      expect(acquireCount, equals(1));

      // 2. Pause one download (active=1, wake-lock still held)
      activeDownloads = 1;
      await BackgroundService.setDownloadActive(false, 'task-1');
      expect(releaseCount, equals(0));

      // 3. Cancel the remaining download (active=0, wake-lock released)
      activeDownloads = 0;
      await BackgroundService.setDownloadActive(false, 'task-2');
      expect(releaseCount, equals(1));
    });

    test('wake-lock counter releases only when internal count reaches 0',
        () async {
      BackgroundService.setActiveDownloadCountQuery(null);
      BackgroundService.resetActiveDownloadCountForTesting();

      await BackgroundService.setDownloadActive(true, 'task-a');
      await BackgroundService.setDownloadActive(true, 'task-b');
      expect(acquireCount, equals(1));
      expect(BackgroundService.activeDownloadCountForTesting, equals(2));

      await BackgroundService.setDownloadActive(false, 'task-a');
      expect(releaseCount, equals(0));
      expect(BackgroundService.activeDownloadCountForTesting, equals(1));

      await BackgroundService.setDownloadActive(false, 'task-b');
      expect(releaseCount, equals(1));
      expect(BackgroundService.activeDownloadCountForTesting, equals(0));
    });
  });
}