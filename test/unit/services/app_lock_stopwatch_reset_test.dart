import 'package:dmx/core/services/app_lock_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppLockService Monotonic Stopwatch Reset Test (P2-12)', () {
    setUp(() {
      AppLockService.resetMonotonicState();
    });

    tearDown(() {
      AppLockService.resetMonotonicState();
    });

    test('resetMonotonicState resets stopwatch elapsed time and mock state',
        () async {
      // Simulate time passing
      AppLockService.mockMonotonicTimeMs = 50000;
      final time1 = await AppLockService.getMonotonicTimeMs();
      expect(time1, equals(50000));

      // Reset monotonic state to simulate app restart
      AppLockService.resetMonotonicState();

      // Ensure mock is cleared and stopwatch is restarted cleanly
      final time2 = await AppLockService.getMonotonicTimeMs();
      expect(time2, lessThan(1000));
    });
  });
}
