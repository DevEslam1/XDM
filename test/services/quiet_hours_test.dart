import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/quiet_hours.dart';

void main() {
  group('QuietHours', () {
    test('same-day range (e.g. 09:00 -> 17:00)', () {
      final inside = DateTime(2026, 1, 1, 14, 30);
      final before = DateTime(2026, 1, 1, 8, 59);
      final after = DateTime(2026, 1, 1, 17, 0);

      expect(
          QuietHours.isInQuietHours(start: '09:00', end: '17:00', now: inside),
          isTrue);
      expect(
          QuietHours.isInQuietHours(start: '09:00', end: '17:00', now: before),
          isFalse);
      expect(
          QuietHours.isInQuietHours(start: '09:00', end: '17:00', now: after),
          isFalse);
    });

    test('overnight range (e.g. 22:00 -> 07:00)', () {
      final lateNight = DateTime(2026, 1, 1, 23, 15);
      final earlyMorning = DateTime(2026, 1, 1, 4, 30);
      final noon = DateTime(2026, 1, 1, 12, 0);

      expect(
          QuietHours.isInQuietHours(
              start: '22:00', end: '07:00', now: lateNight),
          isTrue);
      expect(
          QuietHours.isInQuietHours(
              start: '22:00', end: '07:00', now: earlyMorning),
          isTrue);
      expect(QuietHours.isInQuietHours(start: '22:00', end: '07:00', now: noon),
          isFalse);
    });

    test('start == end returns false (zero length window)', () {
      final now = DateTime(2026, 1, 1, 10, 0);
      expect(QuietHours.isInQuietHours(start: '10:00', end: '10:00', now: now),
          isFalse);
    });

    test('invalid time strings return false', () {
      final now = DateTime(2026, 1, 1, 10, 0);
      expect(
          QuietHours.isInQuietHours(start: 'invalid', end: '10:00', now: now),
          isFalse);
    });
  });
}
