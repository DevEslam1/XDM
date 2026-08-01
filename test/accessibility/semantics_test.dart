import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/shared/accessibility/xdm_semantics.dart';
import 'package:dmx/shared/accessibility/xdm_text_scaler.dart';

void main() {
  group('XdmSemantics Helper Tests', () {
    testWidgets('button semantics are set properly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: XdmSemantics.button(
              label: 'Pause download',
              hint: 'Double tap to pause',
              onTap: () {},
              child: const Icon(Icons.pause),
            ),
          ),
        ),
      );

      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Pause download'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('progress semantics are formatted properly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: XdmSemantics.progress(
              label: 'Download progress',
              value: 0.65,
              child: const LinearProgressIndicator(value: 0.65),
            ),
          ),
        ),
      );

      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Download progress: 65 percent'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('textField semantics set properly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: XdmSemantics.textField(
              label: 'Download URL',
              hint: 'Enter HTTP or magnet URL',
              isRequired: true,
              child: const TextField(),
            ),
          ),
        ),
      );

      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Download URL (Required)'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('toggle semantics set properly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: XdmSemantics.toggle(
              label: 'Wi-Fi only',
              value: true,
              child: Switch(value: true, onChanged: (_) {}),
            ),
          ),
        ),
      );

      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Wi-Fi only'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('XdmTextScaler clamps text scale factor', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: XdmTextScaler(
            child: Builder(
              builder: (context) {
                final scale = MediaQuery.of(context).textScaler.scale(1.0);
                return Text('Scale: $scale');
              },
            ),
          ),
        ),
      );

      expect(find.text('Scale: 1.0'), findsOneWidget);
    });
  });
}
