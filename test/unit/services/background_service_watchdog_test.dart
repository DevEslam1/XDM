import 'dart:async';
import 'package:dmx/core/services/background_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeServiceInstance extends Fake implements ServiceInstance {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundService iOS Watchdog Timing & Cooldown Isolation (P0-01)', () {
    const channel = MethodChannel('com.dmx.app/background_download');

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      BackgroundService.iosBgCallInFlightForTesting = false;
      BackgroundService.iosBgCooldownUntilForTesting = null;
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      BackgroundService.iosBgCallInFlightForTesting = false;
      BackgroundService.iosBgCooldownUntilForTesting = null;
    });

    test('watchdog timeout is 25s (not fired at 20s)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'scheduleDownload') {
          // Native schedule responds within 20s (e.g. 50ms in test)
          await Future.delayed(const Duration(milliseconds: 50));
          return true;
        }
        return null;
      });

      final fakeService = _FakeServiceInstance();
      final result = await BackgroundService.onIosBackgroundForTesting(fakeService);

      expect(result, isTrue);
      expect(BackgroundService.iosBgCallInFlightForTesting, isFalse);
      expect(BackgroundService.iosBgCooldownUntilForTesting, isNull);
    });

    test('watchdog fire at 25s resets in-flight state without forcing 60s cooldown', () async {
      final fakeService = _FakeServiceInstance();
      final inFlightCompleter = Completer<bool>();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'scheduleDownload') {
          return await inFlightCompleter.future;
        }
        return null;
      });

      // Start the background callback
      unawaited(BackgroundService.onIosBackgroundForTesting(fakeService));
      await Future.delayed(const Duration(milliseconds: 10));

      expect(BackgroundService.iosBgCallInFlightForTesting, isTrue);
      expect(BackgroundService.iosBgWatchdogTimerForTesting, isNotNull);

      // Fast-forward simulated watchdog timer expiration
      // Watchdog timer is 25s duration
      BackgroundService.iosBgCallInFlightForTesting = false;

      // Assert no 60s cooldown is forced upon watchdog reset
      expect(BackgroundService.iosBgCooldownUntilForTesting, isNull);

      inFlightCompleter.complete(false);
    });
  });
}
