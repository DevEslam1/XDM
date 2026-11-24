import 'package:dmx/core/services/undo_service.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  Widget wrap(Builder builder) {
    return ChangeNotifierProvider<SettingsProvider>.value(
      value: SettingsProvider.instance,
      child: MaterialApp(home: Scaffold(body: builder)),
    );
  }

  group('UndoService', () {
    test('UndoAction exposes its label and restore callback', () async {
      var restored = false;
      final action = UndoAction(
        label: 'Delete',
        restore: () async => restored = true,
      );
      expect(action.label, 'Delete');
      await action.restore();
      expect(restored, isTrue);
    });

    testWidgets('commits the action when undo is not tapped', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        wrap(Builder(builder: (context) {
          ctx = context;
          return const SizedBox.shrink();
        })),
      );

      var actionCalled = false;
      var undoCalled = false;

      final future = UndoService.instance.execute(
        context: ctx,
        message: 'Deleted item A',
        action: () async => actionCalled = true,
        undo: () async => undoCalled = true,
        duration: const Duration(milliseconds: 30),
      );
      await tester.pump(const Duration(milliseconds: 40));
      await future;

      expect(actionCalled, isTrue);
      expect(undoCalled, isFalse);
    });

    testWidgets('runs undo and skips the action when tapped', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        wrap(Builder(builder: (context) {
          ctx = context;
          return const SizedBox.shrink();
        })),
      );

      var actionCalled = false;
      var undoCalled = false;

      final future = UndoService.instance.execute(
        context: ctx,
        message: 'Deleted item B',
        action: () async => actionCalled = true,
        undo: () async => undoCalled = true,
        duration: const Duration(seconds: 5),
        isDarkMode: false,
      );

      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('UNDO'), findsOneWidget);
      final actionButton = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('UNDO'),
          matching: find.byType(TextButton),
        ),
      );
      actionButton.onPressed!();
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await future;

      expect(undoCalled, isTrue);
      expect(actionCalled, isFalse);
    });
  });
}
