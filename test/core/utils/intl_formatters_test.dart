import 'package:dmx/core/utils/intl_formatters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('formatLocalizedNumber uses the ambient locale', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        home: Builder(
          builder: (context) {
            expect(formatLocalizedNumber(context, 1234567), isNotEmpty);
            expect(formatLocalizedNumber(context, 0), isNotEmpty);
            return const SizedBox();
          },
        ),
      ),
    );
  });

  testWidgets('formatLocalizedDateTime and Time format real dates',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        home: Builder(
          builder: (context) {
            final value = DateTime(2024, 5, 6, 14, 30);
            final dateTime = formatLocalizedDateTime(context, value);
            final time = formatLocalizedTime(context, value);
            expect(dateTime, isNot('—'));
            expect(time, isNot('—'));
            expect(dateTime, isNotEmpty);
            expect(time, isNotEmpty);
            return const SizedBox();
          },
        ),
      ),
    );
  });

  testWidgets('non-positive timestamps render the em-dash placeholder',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        home: Builder(
          builder: (context) {
            expect(
              formatLocalizedDateTime(
                  context, DateTime.fromMillisecondsSinceEpoch(0)),
              '—',
            );
            expect(
              formatLocalizedTime(
                  context, DateTime.fromMillisecondsSinceEpoch(-1)),
              '—',
            );
            return const SizedBox();
          },
        ),
      ),
    );
  });
}
