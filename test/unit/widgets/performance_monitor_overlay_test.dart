import 'package:dmx/core/services/background_gate.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/shared/widgets/performance_monitor_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PerformanceMonitorOverlay Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (methodCall) async => null,
      );
      await SettingsProvider.instance.load();
    });

    testWidgets('toggling Reduce motion flips BackgroundGate.shouldAnimate',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PerformanceMonitorOverlay(
              child: SizedBox.expand(
                child: Text('App Content'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('App Content'), findsOneWidget);
      expect(find.text('Reduce motion'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('reduce_motion_toggle')),
        warnIfMissed: false,
      );
      await tester.pump();

      expect(BackgroundGate.shouldAnimate, isFalse);

      await tester.tap(
        find.byKey(const ValueKey('reduce_motion_toggle')),
        warnIfMissed: false,
      );
      await tester.pump();

      expect(BackgroundGate.shouldAnimate, isTrue);
    });
  });
}
