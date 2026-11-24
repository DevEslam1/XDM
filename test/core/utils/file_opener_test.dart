import 'package:dmx/core/utils/file_opener.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('non-existent path shows the English error snackbar',
      (tester) async {
    final settings = createMockSettingsProvider();

    await tester.pumpWidget(
      createTestApp(
        settingsProvider: settings,
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => openFile(
              context,
              '/definitely/not/a/real/file.bin',
              settings,
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('File does not exist'), findsOneWidget);
  });

  testWidgets('empty path with Arabic locale shows the localized message',
      (tester) async {
    final settings = createMockSettingsProvider();
    settings.languageCode = 'ar';

    await tester.pumpWidget(
      createTestApp(
        settingsProvider: settings,
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => openFile(context, '', settings),
            child: const Text('go'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('الملف غير موجود'), findsOneWidget);
  });
}
