import 'package:battery_plus/battery_plus.dart';
import 'package:dmx/core/services/background_gate.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/shared/widgets/glass_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GlassCard BackdropFilter Guard Tests', () {
    setUp(() {
      BackgroundGate.shouldAnimate = true;
      PowerMonitor.isLowEndDevice = false;
      PowerMonitor.setBatteryForTesting(
        level: 100,
        state: BatteryState.discharging,
      );
      PowerMonitor.setThermalForTesting(ThermalStatus.none);
    });

    tearDown(() {
      BackgroundGate.shouldAnimate = true;
      PowerMonitor.setBatteryForTesting(
        level: 100,
        state: BatteryState.discharging,
      );
      PowerMonitor.setThermalForTesting(ThermalStatus.none);
    });

    testWidgets(
        'renders fallback Container and no BackdropFilter when batterySaverMode == aggressive',
        (tester) async {
      // Set battery to 10% to trigger aggressive battery saver mode
      PowerMonitor.setBatteryForTesting(
        level: 10,
        state: BatteryState.discharging,
      );
      expect(PowerMonitor.batterySaverMode.isAggressive, isTrue);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GlassCard(
              enableBlur: true,
              child: Text('Card in Power Saver'),
            ),
          ),
        ),
      );

      expect(find.text('Card in Power Saver'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(Container), findsWidgets);
    });

    testWidgets(
        'GlassCard renders solid surface and never allocates a BackdropFilter '
        'even when blur is enabled under normal conditions', (tester) async {
      PowerMonitor.setBatteryForTesting(
        level: 100,
        state: BatteryState.discharging,
      );
      expect(PowerMonitor.batterySaverMode.isAggressive, isFalse);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GlassCard(
              enableBlur: true,
              child: Text('Card in Normal Power'),
            ),
          ),
        ),
      );

      expect(find.text('Card in Normal Power'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('GlassCard.listItem factory is non-blurred', (tester) async {
      PowerMonitor.setBatteryForTesting(
        level: 100,
        state: BatteryState.discharging,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GlassCard.listItem(
              child: Text('List Item Card'),
            ),
          ),
        ),
      );

      expect(find.text('List Item Card'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
    });
  });
}
