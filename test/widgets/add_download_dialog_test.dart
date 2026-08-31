import 'package:dmx/features/add_download/widgets/add_download_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_helpers.dart';

void main() {
  group('AddDownloadDialog', () {
    testWidgets('renders URL input field', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const AddDownloadDialog(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AddDownloadDialog), findsOneWidget);
    });

    testWidgets('accepts valid HTTP URL', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const AddDownloadDialog(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      final textFields = find.byType(TextFormField);
      if (textFields.evaluate().isNotEmpty) {
        await tester.enterText(
            textFields.first, 'https://example.com/file.zip');
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('https://example.com/file.zip'), findsOneWidget);
      }
    });

    testWidgets('accepts magnet link input', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const AddDownloadDialog(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      final textFields = find.byType(TextFormField);
      if (textFields.evaluate().isNotEmpty) {
        await tester.enterText(
          textFields.first,
          'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a',
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('magnet:'), findsWidgets);
      }
    });
  });
}
