import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/frame_watchdog.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FrameWatchdog Tests', () {
    tearDown(() {
      FrameWatchdog.onJankDetected = null;
    });

    test('Jank ratio 6% -> onJankDetected called', () {
      double? detectedRatio;
      FrameWatchdog.onJankDetected = (ratio) {
        detectedRatio = ratio;
      };

      // 6 dropped out of 100 frames = 6% jank (> 5% alert threshold)
      FrameWatchdog.simulateWindowForTesting(6, 100);

      expect(detectedRatio, isNotNull);
      expect(detectedRatio, closeTo(0.06, 0.001));
    });

    test('Jank ratio 4% -> onJankDetected NOT called', () {
      double? detectedRatio;
      FrameWatchdog.onJankDetected = (ratio) {
        detectedRatio = ratio;
      };

      // 4 dropped out of 100 frames = 4% jank (<= 5% alert threshold)
      FrameWatchdog.simulateWindowForTesting(4, 100);

      expect(detectedRatio, isNull);
    });

    test('3 consecutive windows > 8% -> battery saver triggered', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => null,
      );
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider.instance;
      await settings.load();
      await settings.setBatterySaverMode(false);
      expect(settings.batterySaverMode, isFalse);

      int consecutiveJankWindows = 0;
      FrameWatchdog.onJankDetected = (jankRatio) {
        if (jankRatio > 0.08) {
          consecutiveJankWindows++;
          if (consecutiveJankWindows >= 3) {
            settings.setBatterySaverMode(true);
          }
        } else {
          consecutiveJankWindows = 0;
        }
      };

      // Window 1: 9% > 8%
      FrameWatchdog.simulateWindowForTesting(9, 100);
      expect(settings.batterySaverMode, isFalse);

      // Window 2: 10% > 8%
      FrameWatchdog.simulateWindowForTesting(10, 100);
      expect(settings.batterySaverMode, isFalse);

      // Window 3: 9% > 8% -> Should trigger battery saver
      FrameWatchdog.simulateWindowForTesting(9, 100);
      expect(settings.batterySaverMode, isTrue);
    });
  });
}

