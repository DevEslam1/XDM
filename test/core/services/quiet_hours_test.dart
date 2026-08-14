import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/quiet_hours.dart';

void main() {
  group('QuietHours', () {
    test('standard daytime window detects time inside accurately', () {
      final now = DateTime(2026, 1, 1, 14, 30); // 14:30
      expect(QuietHours.isInQuietHours(start: '13:00', end: '16:00', now: now), true);
      expect(QuietHours.isInQuietHours(start: '09:00', end: '12:00', now: now), false);
    });

    test('midnight wrapping window detects times before and after midnight', () {
      final lateNight = DateTime(2026, 1, 1, 23, 30); // 23:30
      final earlyMorning = DateTime(2026, 1, 1, 5, 15); // 05:15
      final noon = DateTime(2026, 1, 1, 12, 0); // 12:00

      expect(QuietHours.isInQuietHours(start: '22:00', end: '07:00', now: lateNight), true);
      expect(QuietHours.isInQuietHours(start: '22:00', end: '07:00', now: earlyMorning), true);
      expect(QuietHours.isInQuietHours(start: '22:00', end: '07:00', now: noon), false);
    });

    test('window boundary is inclusive of start and exclusive of end', () {
      final atStart = DateTime(2026, 1, 1, 10, 0);
      final atEnd = DateTime(2026, 1, 1, 11, 0);

      expect(QuietHours.isInQuietHours(start: '10:00', end: '11:00', now: atStart), true);
      expect(QuietHours.isInQuietHours(start: '10:00', end: '11:00', now: atEnd), false);
    });

    test('identical start and end creates inactive zero-length window', () {
      final now = DateTime(2026, 1, 1, 10, 0);
      expect(QuietHours.isInQuietHours(start: '10:00', end: '10:00', now: now), false);
    });

    test('invalid or malformed time strings fail closed (return false)', () {
      final now = DateTime(2026, 1, 1, 10, 0);
      expect(QuietHours.isInQuietHours(start: 'invalid', end: '12:00', now: now), false);
      expect(QuietHours.isInQuietHours(start: '10:00', end: '25:99', now: now), false);
      expect(QuietHours.isInQuietHours(start: '', end: '', now: now), false);
    });
  });
}
