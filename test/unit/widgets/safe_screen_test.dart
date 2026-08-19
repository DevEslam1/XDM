import 'package:dmx/shared/widgets/safe_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SafeScreen renders child properly in normal state',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SafeScreen(
          screenName: 'TestScreen',
          child: Text('Normal Screen Content'),
        ),
      ),
    );

    expect(find.text('Normal Screen Content'), findsOneWidget);
  });
}
