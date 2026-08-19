import 'package:dmx/core/services/background_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    BackgroundService.testMode = true;
    BackgroundService.resetActiveDownloadCountForTesting();
    BackgroundService.iosBgCallInFlightForTesting = false;
    BackgroundService.iosBgCooldownUntilForTesting = null;
  });

  tearDown(() async {
    BackgroundService.resetActiveDownloadCountForTesting();
    BackgroundService.iosBgCallInFlightForTesting = false;
    BackgroundService.iosBgCooldownUntilForTesting = null;
  });

  group('BackgroundService Hardening (Sprint 1)', () {
    test('Cooldown prevents iOS background invocation while active', () async {
      BackgroundService.iosBgCooldownUntilForTesting =
          DateTime.now().add(const Duration(seconds: 30));

      final success = await BackgroundService.onIosBackgroundForTesting();
      expect(success, isFalse);
    });

    test(
        'Exponential backoff increments delays on repeated failures and clears on success',
        () async {
      expect(await BackgroundService.shouldThrottleForBackoff(), isFalse);

      // Failure 1: 30s
      await BackgroundService.recordBackgroundFailure();
      expect(await BackgroundService.shouldThrottleForBackoff(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('bg_consecutive_failures'), equals(1));

      // Failure 2: 2m
      await BackgroundService.recordBackgroundFailure();
      expect(prefs.getInt('bg_consecutive_failures'), equals(2));

      // Success clears
      await BackgroundService.recordBackgroundSuccess();
      expect(await BackgroundService.shouldThrottleForBackoff(), isFalse);
      expect(prefs.getInt('bg_consecutive_failures'), isNull);
    });
  });
}
