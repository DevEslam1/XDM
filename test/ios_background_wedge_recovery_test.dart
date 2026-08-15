import 'package:dmx/core/services/background_service.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeServiceInstance extends Fake implements ServiceInstance {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('iOS Background Wedge Recovery (P0-3)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      BackgroundService.iosBgCallInFlightForTesting = false;
    });

    test('Flag resets to false on normal completion or error inside try/finally', () async {
      expect(BackgroundService.iosBgCallInFlightForTesting, isFalse);

      final fakeService = _FakeServiceInstance();
      final result = await BackgroundService.onIosBackgroundForTesting(fakeService);

      // Method channel call returns false in test environment, but flag must be safely reset
      expect(result, isFalse);
      expect(BackgroundService.iosBgCallInFlightForTesting, isFalse);
    });

    test('Duplicate concurrent invocation is ignored when in-flight is true', () async {
      BackgroundService.iosBgCallInFlightForTesting = true;

      final fakeService = _FakeServiceInstance();
      final result = await BackgroundService.onIosBackgroundForTesting(fakeService);

      expect(result, isFalse);
      expect(BackgroundService.iosBgCallInFlightForTesting, isTrue);

      BackgroundService.iosBgCallInFlightForTesting = false;
    });
  });
}
