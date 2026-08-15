import 'package:dmx/core/services/background_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockServiceInstance extends Fake implements ServiceInstance {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundService iOS Duplicate Invocation Guard', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.dmx.app/background_download'),
        null,
      );
    });

    test('scheduleDownload is invoked exactly once per callback', () async {
      int invokeCount = 0;
      const channel = MethodChannel('com.dmx.app/background_download');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'scheduleDownload') {
          invokeCount++;
          await Future.delayed(const Duration(milliseconds: 10));
          return true;
        }
        return null;
      });

      final dummy = _MockServiceInstance();
      final result = await BackgroundService.onIosBackgroundForTesting(dummy);

      expect(result, isTrue);
      expect(invokeCount, 1);
    });

    test('concurrent duplicate calls are rejected by in-flight guard', () async {
      int invokeCount = 0;
      const channel = MethodChannel('com.dmx.app/background_download');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'scheduleDownload') {
          invokeCount++;
          await Future.delayed(const Duration(milliseconds: 50));
          return true;
        }
        return null;
      });

      final dummy = _MockServiceInstance();
      final future1 = BackgroundService.onIosBackgroundForTesting(dummy);
      final future2 = BackgroundService.onIosBackgroundForTesting(dummy);

      final results = await Future.wait([future1, future2]);

      expect(results[0], isTrue);
      expect(results[1], isFalse); // guarded duplicate call
      expect(invokeCount, 1);
    });
  });
}
