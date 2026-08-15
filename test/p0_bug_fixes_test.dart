import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/shared/widgets/geometric_grid_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P0 Critical Bug Fix Tests', () {
    testWidgets(
        'FIX-03: GeometricGridBackground widget mounts and disposes without refCount underflow',
        (tester) async {
      final settings = SettingsProvider.instance;
      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: const MaterialApp(
            home: GeometricGridBackground(
              child: SizedBox(),
            ),
          ),
        ),
      );
      expect(find.byType(GeometricGridBackground), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(find.byType(GeometricGridBackground), findsNothing);
    });
  });
}
