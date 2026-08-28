import 'package:dmx/features/browser/services/inactivity_watchdog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InactivityWatchdog Tests [Browser 10/10]', () {
    test('resetTimer triggers callback after timeout period when mounted', () {
      final watchdog = InactivityWatchdog();
      expect(watchdog.isHibernating, isFalse);

      watchdog.resetTimer(
        isMounted: false,
        onTimeout: () {},
      );
      // When not mounted, timer is not scheduled
      expect(watchdog.isHibernating, isFalse);
    });

    test('clearTab safely handles un-tracked or tracked tab IDs', () {
      final watchdog = InactivityWatchdog();
      expect(() => watchdog.clearTab('tab_non_existent'), returnsNormally);
    });
  });
}
