import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/shared/widgets/dmx_backdrop_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DmxBackdropFilter Tests', () {
    setUp(() {
      DmxBackdropFilter.resetActiveCount();
    });

    tearDown(() {
      DmxBackdropFilter.resetActiveCount();
    });

    testWidgets('renders solid Container when forceSolid is true',
        (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: SettingsProvider.instance,
          child: const MaterialApp(
            home: Scaffold(
              body: DmxBackdropFilter(
                sigmaX: 10,
                sigmaY: 10,
                forceSolid: true,
                child: Text('Solid Fallback'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Solid Fallback'), findsOneWidget);
      expect(DmxBackdropFilter.activeCount, equals(0));
    });

    testWidgets('increments activeCount when below max concurrent limit',
        (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: SettingsProvider.instance,
          child: const MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  DmxBackdropFilter(
                    sigmaX: 10,
                    sigmaY: 10,
                    child: Text('Card 1'),
                  ),
                  DmxBackdropFilter(
                    sigmaX: 10,
                    sigmaY: 10,
                    child: Text('Card 2'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('Card 1'), findsOneWidget);
      expect(find.text('Card 2'), findsOneWidget);
      expect(DmxBackdropFilter.activeCount, equals(1));
    });

    testWidgets('respects DmxBackdropFilter.disabled flag', (tester) async {
      DmxBackdropFilter.disabled = true;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: SettingsProvider.instance,
          child: const MaterialApp(
            home: Scaffold(
              body: DmxBackdropFilter(
                sigmaX: 10,
                sigmaY: 10,
                child: Text('Disabled Blur'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Disabled Blur'), findsOneWidget);
      expect(DmxBackdropFilter.activeCount, equals(0));
      DmxBackdropFilter.disabled = false;
    });
  });
}
