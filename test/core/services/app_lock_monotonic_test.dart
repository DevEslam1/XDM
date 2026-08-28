import 'package:dmx/core/services/app_lock_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppLockService.resetMonotonicState();
  });

  tearDown(() {
    AppLockService.resetMonotonicState();
  });

  group('AppLockService Monotonic Clock Tests', () {
    test('getMonotonicTimeMs returns mockMonotonicTimeMs when set', () async {
      AppLockService.mockMonotonicTimeMs = 123456789;
      final time = await AppLockService.getMonotonicTimeMs();
      expect(time, equals(123456789));
    });

    test(
        'getMonotonicTimeMs returns positive monotonic time using stopwatch fallback when channel fails',
        () async {
      AppLockService.mockMonotonicTimeMs = null;
      final t1 = await AppLockService.getMonotonicTimeMs();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final t2 = await AppLockService.getMonotonicTimeMs();
      expect(t1, isNonNegative);
      expect(t2, greaterThanOrEqualTo(t1));
    });
  });
}
