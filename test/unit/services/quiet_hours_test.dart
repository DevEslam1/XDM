import 'package:dmx/core/services/quiet_hours.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DateTime at(String time) {
    final parts = time.split(':');
    return DateTime(2026, 1, 1, int.parse(parts[0]), int.parse(parts[1]));
  }

  group('QuietHours.isInQuietHours', () {
    test('within a same-day window', () {
      expect(
        QuietHours.isInQuietHours(
          start: '09:00',
          end: '17:00',
          now: at('10:00'),
        ),
        isTrue,
      );
      expect(
        QuietHours.isInQuietHours(
          start: '09:00',
          end: '17:00',
          now: at('08:59'),
        ),
        isFalse,
      );
      expect(
        QuietHours.isInQuietHours(
          start: '09:00',
          end: '17:00',
          now: at('17:00'),
        ),
        isFalse,
      );
    });

    test('window wrapping past midnight', () {
      expect(
        QuietHours.isInQuietHours(
          start: '23:00',
          end: '07:00',
          now: at('23:30'),
        ),
        isTrue,
      );
      expect(
        QuietHours.isInQuietHours(
          start: '23:00',
          end: '07:00',
          now: at('02:00'),
        ),
        isTrue,
      );
      expect(
        QuietHours.isInQuietHours(
          start: '23:00',
          end: '07:00',
          now: at('12:00'),
        ),
        isFalse,
      );
    });

    test('invalid times never count as quiet', () {
      expect(
        QuietHours.isInQuietHours(start: 'garbage', end: '07:00', now: at('01:00')),
        isFalse,
      );
      expect(
        QuietHours.isInQuietHours(start: '23:00', end: '25:00', now: at('01:00')),
        isFalse,
      );
      expect(
        QuietHours.isInQuietHours(start: '23:00', end: '', now: at('01:00')),
        isFalse,
      );
    });

    test('zero-length window is inactive', () {
      expect(
        QuietHours.isInQuietHours(start: '12:00', end: '12:00', now: at('12:00')),
        isFalse,
      );
    });
  });
}
