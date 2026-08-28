import 'package:battery_plus/battery_plus.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/shared/widgets/dmx_backdrop_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DmxBackdropFilter Tests', () {
    setUp(() async {
      setupTestPluginMocks();
      SharedPreferences.setMockInitialValues(
          {'classicUi': false, 'reduceVisuals': false});
      await SettingsProvider.instance.load();
      await SettingsProvider.instance.setClassicUi(false);
      await SettingsProvider.instance.setReduceVisuals(false);
      DmxBackdropFilter.resetActiveCount();
      DmxBackdropFilter.disabled = false;
      DownloadEngine.appInForeground = true;
      PowerMonitor.screenOff = false;
      PowerMonitor.isLowEndDevice = false;
      PowerMonitor.setBatteryForTesting(
          level: 100, state: BatteryState.charging);
      PowerMonitor.setThermalForTesting(ThermalStatus.none);
    });

    tearDown(() {
      DmxBackdropFilter.resetActiveCount();
      DmxBackdropFilter.disabled = false;
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
