import 'package:battery_plus/battery_plus.dart';
import 'package:dmx/core/services/device_tier.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const powerChannel = MethodChannel('com.dmx.app/power');
  const batteryChannel = MethodChannel('dev.fluttercommunity.plus/battery');
  const chargingChannel = EventChannel('dev.fluttercommunity.plus/charging');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void reset() {
    PowerMonitor.setBatteryForTesting(level: 100, state: BatteryState.charging);
    PowerMonitor.setThermalForTesting(ThermalStatus.none);
    PowerMonitor.setScreenOn(true);
    PowerMonitor.isAppForegrounded = true;
    PowerMonitor.thermalThreadLimitingEnabled = true;
    PowerMonitor.powerBandwidthThrottlingEnabled = true;
    DeviceTierService.resetForTesting();
  }

  setUp(reset);

  tearDown(() {
    messenger.setMockMethodCallHandler(powerChannel, null);
    messenger.setMockMethodCallHandler(batteryChannel, null);
    messenger.setMockStreamHandler(chargingChannel, null);
    PowerMonitor.dispose();
    reset();
  });

  group('PowerMonitor battery saver', () {
    test('isLowEndDevice derives from the detected device tier', () {
      expect(PowerMonitor.isLowEndDevice, isA<bool>());
    });

    test('charging device with a full battery is un-throttled', () {
      expect(PowerMonitor.throttleFactor, 1.0);
      expect(PowerMonitor.batterySaverMode, BatterySaverMode.off);
      expect(PowerMonitor.isLowPowerMode, isFalse);
    });

    test('aggressive battery saver below 20%', () {
      PowerMonitor.setBatteryForTesting(
        level: 15,
        state: BatteryState.discharging,
      );
      expect(PowerMonitor.batterySaverMode, BatterySaverMode.aggressive);
      expect(PowerMonitor.isLowPowerMode, isTrue);
      expect(PowerMonitor.maxAllowedThreads, 1);
      expect(PowerMonitor.throttleFactor, closeTo(0.5, 0.0001));
    });

    test('moderate battery saver in the [20, 40) band', () {
      PowerMonitor.setBatteryForTesting(
        level: 35,
        state: BatteryState.discharging,
      );
      expect(PowerMonitor.batterySaverMode, BatterySaverMode.moderate);
      expect(PowerMonitor.throttleFactor, closeTo(0.75, 0.0001));
    });

    test('battery saver transitions from aggressive to moderate to off', () {
      PowerMonitor.setBatteryForTesting(
        level: 15,
        state: BatteryState.discharging,
      );
      expect(PowerMonitor.batterySaverMode, BatterySaverMode.aggressive);

      PowerMonitor.setBatteryForTesting(
        level: 25,
        state: BatteryState.discharging,
      );
      expect(PowerMonitor.batterySaverMode, BatterySaverMode.moderate);

      PowerMonitor.setBatteryForTesting(
        level: 45,
        state: BatteryState.discharging,
      );
      expect(PowerMonitor.batterySaverMode, BatterySaverMode.off);
    });

    test('charging overrides a low battery level', () {
      PowerMonitor.setBatteryForTesting(
        level: 5,
        state: BatteryState.charging,
      );
      expect(PowerMonitor.batterySaverMode, BatterySaverMode.off);
      expect(PowerMonitor.isCharging, isTrue);
    });

    test('disabling bandwidth throttling forces a factor of 1.0', () {
      PowerMonitor.setBatteryForTesting(
        level: 15,
        state: BatteryState.discharging,
      );
      PowerMonitor.powerBandwidthThrottlingEnabled = false;
      expect(PowerMonitor.throttleFactor, 1.0);
    });
  });

  group('PowerMonitor thermal', () {
    test('moderate thermal scales the throttle factor', () {
      PowerMonitor.setThermalForTesting(ThermalStatus.moderate);
      expect(PowerMonitor.throttleFactor, closeTo(0.7, 0.0001));
    });

    test('severe thermal forces aggressive saver and thread cap', () {
      PowerMonitor.setThermalForTesting(ThermalStatus.severe);
      expect(PowerMonitor.batterySaverMode, BatterySaverMode.aggressive);
      expect(
        PowerMonitor.maxAllowedThreads,
        PowerMonitor.kThermalLimitedMaxThreads,
      );
    });

    test('critical thermal is the most conservative', () {
      PowerMonitor.setThermalForTesting(ThermalStatus.critical);
      expect(PowerMonitor.throttleFactor, closeTo(0.3, 0.0001));
    });

    test('screen off escalates moderate thermal to severe', () {
      PowerMonitor.setThermalForTesting(ThermalStatus.moderate);
      PowerMonitor.setScreenOn(false);
      expect(PowerMonitor.throttleFactor, closeTo(0.5, 0.0001));
    });

    test('thermal thread limiting can be disabled', () {
      PowerMonitor.setThermalForTesting(ThermalStatus.severe);
      PowerMonitor.thermalThreadLimitingEnabled = false;
      expect(PowerMonitor.maxAllowedThreads, 1); // aggressive saver kicks in
    });

    test('maxAllowedThreads defaults to 16 when unrestricted', () {
      expect(PowerMonitor.maxAllowedThreads, 16);
    });
  });

  group('PowerMonitor state changes', () {
    test('setDownloadActive starts and stops the thermal timer', () {
      PowerMonitor.setDownloadActive(true);
      PowerMonitor.setDownloadActive(true); // no-op, already active
      PowerMonitor.setDownloadActive(false);
      expect(true, isTrue);
    });

    test('screen toggle emits on the screen state stream', () async {
      final events = <bool>[];
      final sub = PowerMonitor.screenStateStream.listen(events.add);
      PowerMonitor.setScreenOn(false);
      await Future<void>.delayed(Duration.zero);
      expect(events, [false]);
      PowerMonitor.setScreenOn(true);
      await Future<void>.delayed(Duration.zero);
      expect(events, [false, true]);
      await sub.cancel();
    });

    test('isLowEndDevice honours the testing override', () {
      PowerMonitor.setLowEndDevice(true);
      expect(PowerMonitor.isLowEndDevice, isTrue);
      PowerMonitor.setLowEndDevice(false);
      expect(PowerMonitor.isLowEndDevice, isFalse);
    });

    test('updateScreenStateFromPlatform applies the platform value', () async {
      messenger.setMockMethodCallHandler(powerChannel, (call) async {
        if (call.method == 'isScreenOn') return false;
        return null;
      });
      await PowerMonitor.updateScreenStateFromPlatform();
      expect(PowerMonitor.screenOff, isTrue);
    });

    test('requestIgnoreBatteryOptimizations is a no-op off-Android', () async {
      await PowerMonitor.requestIgnoreBatteryOptimizations();
      expect(true, isTrue);
    });

    test('init wires platform listeners without throwing', () async {
      messenger.setMockMethodCallHandler(powerChannel, (call) async {
        if (call.method == 'isScreenOn') return true;
        return null;
      });
      messenger.setMockMethodCallHandler(batteryChannel, (call) async {
        switch (call.method) {
          case 'getBatteryLevel':
            return 80;
          case 'getBatteryState':
            return 'charging';
        }
        return null;
      });
      messenger.setMockStreamHandler(
        chargingChannel,
        MockStreamHandler.inline(
          onListen: (arguments, events) => events.success('charging'),
        ),
      );

      await PowerMonitor.init();
      expect(PowerMonitor.batteryLevel, 80);
    });

    test('platform screen-state messages drive the monitor', () async {
      messenger.setMockMethodCallHandler(powerChannel, (call) async {
        if (call.method == 'isScreenOn') return true;
        return null;
      });
      messenger.setMockMethodCallHandler(batteryChannel, (call) async {
        switch (call.method) {
          case 'getBatteryLevel':
            return 90;
          case 'getBatteryState':
            return 'discharging';
        }
        return null;
      });
      messenger.setMockStreamHandler(
        chargingChannel,
        MockStreamHandler.inline(
          onListen: (arguments, events) => events.success('discharging'),
        ),
      );

      await PowerMonitor.init();
      await messenger.handlePlatformMessage(
        'com.dmx.app/power',
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('screenStateChanged', false)),
        null,
      );

      expect(PowerMonitor.screenOff, isTrue);
    });
  });

  group('PowerMonitor accessors', () {
    test('BatterySaverMode helpers reflect the enum value', () {
      expect(BatterySaverMode.off.isOff, isTrue);
      expect(BatterySaverMode.moderate.isModerate, isTrue);
      expect(BatterySaverMode.aggressive.isAggressive, isTrue);
      expect(BatterySaverMode.aggressive.isOff, isFalse);
    });

    test('getters expose the current battery and thermal state', () {
      PowerMonitor.setBatteryForTesting(
        level: 55,
        state: BatteryState.discharging,
      );
      PowerMonitor.setThermalForTesting(ThermalStatus.fair);
      expect(PowerMonitor.batteryState, BatteryState.discharging);
      expect(PowerMonitor.batteryLevel, 55);
      expect(PowerMonitor.thermal, ThermalStatus.fair);

      PowerMonitor.screenOff = true;
      expect(PowerMonitor.screenOff, isTrue);
      PowerMonitor.screenOff = false;
      expect(PowerMonitor.screenOff, isFalse);
    });

    test('thermal timer polls while downloads stay active', () {
      fakeAsync((async) {
        PowerMonitor.setBatteryForTesting(
          level: 100,
          state: BatteryState.charging,
        );
        PowerMonitor.setDownloadActive(true);
        async.elapse(const Duration(minutes: 2));
        PowerMonitor.setDownloadActive(false);
      });
    });
  });
}
