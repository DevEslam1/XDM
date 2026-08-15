import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/background_service.dart';

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
    });

    test('wake-lock is held while active > 0 and released when active drops to 0', () async {
      // 1. Start 2 downloads
      activeDownloads = 2;
      await BackgroundService.setDownloadActive(true);
      expect(acquireCount, equals(1));

      // 2. Pause one download (active=1, wake-lock still held)
      activeDownloads = 1;
      await BackgroundService.setDownloadActive(false);
      expect(releaseCount, equals(0));

      // 3. Cancel the remaining download (active=0, wake-lock released)
      activeDownloads = 0;
      await BackgroundService.setDownloadActive(false);
      expect(releaseCount, equals(1));
    });
  });
}
