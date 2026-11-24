import 'package:dmx/core/domain/pause_reason.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PauseReason', () {
    test('aliases', () {
      expect(PauseReason.userRequested, PauseReason.user);
      expect(PauseReason.batteryLow, PauseReason.batterySaver);
      expect(PauseReason.systemBackground, PauseReason.background);
    });

    test('derived getters', () {
      expect(PauseReason.user.isUserInitiated, isTrue);
      expect(PauseReason.background.isUserInitiated, isFalse);
      expect(PauseReason.user.blocksAutoResume, isTrue);
      expect(PauseReason.networkLost.blocksAutoResume, isFalse);
    });

    test('fromName exact matches', () {
      for (final v in PauseReason.values) {
        expect(PauseReason.fromName(v.name), v);
      }
    });

    test('fromName aliases and fallbacks', () {
      expect(PauseReason.fromName('user_requested'), PauseReason.user);
      expect(PauseReason.fromName('userrequested'), PauseReason.user);
      expect(PauseReason.fromName('system_background'), PauseReason.background);
      expect(PauseReason.fromName('systembackground'), PauseReason.background);
      expect(PauseReason.fromName('battery_saver'), PauseReason.batterySaver);
      expect(PauseReason.fromName('batterylow'), PauseReason.batterySaver);
      expect(PauseReason.fromName('battery_low'), PauseReason.batterySaver);
      expect(PauseReason.fromName('disk_full'), PauseReason.diskFull);
      expect(PauseReason.fromName('network_lost'), PauseReason.networkLost);
      expect(PauseReason.fromName('app_restarted'), PauseReason.appRestarted);
      expect(PauseReason.fromName('url_expired'), PauseReason.urlExpired);
      expect(PauseReason.fromName('permission_revoked'),
          PauseReason.permissionRevoked);
      expect(PauseReason.fromName('permission'), PauseReason.permissionRevoked);
      expect(PauseReason.fromName('hard_timeout'), PauseReason.timeout);
      expect(PauseReason.fromName('hardtimeout'), PauseReason.timeout);
    });

    test('fromName null/empty and unknown fallback', () {
      expect(PauseReason.fromName(null), PauseReason.unknown);
      expect(PauseReason.fromName(''), PauseReason.unknown);
      expect(PauseReason.fromName('   '), PauseReason.unknown);
      expect(PauseReason.fromName('bogus'), PauseReason.unknown);
      expect(PauseReason.fromName('bogus', fallback: null), isNull);
      expect(PauseReason.fromName(null, fallback: PauseReason.user),
          PauseReason.user);
    });
  });
}
