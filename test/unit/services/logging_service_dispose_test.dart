import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/logging_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LoggingService Dispose & Timer Cleanup (NEW-05)', () {
    test('dispose cancels active flush timer and cleans up state', () {
      final timer = Timer(const Duration(seconds: 30), () {});
      LoggingService.setReleaseFlushTimerForTesting(timer);
      expect(LoggingService.hasActiveTimer, isTrue);

      LoggingService.dispose();
      expect(LoggingService.hasActiveTimer, isFalse);
      expect(timer.isActive, isFalse);
    });
  });
}
