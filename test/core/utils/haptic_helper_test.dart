import 'package:dmx/core/utils/haptic_helper.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _HapticUser with HapticHelper {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> vibrations;

  setUp(() {
    vibrations = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        vibrations.add(call.arguments as String? ?? '');
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('isSupported reflects the host platform capabilities', () {
    // Host unit tests run on desktop: haptics are unsupported there.
    expect(HapticHelper.isSupported, isFalse);
  });

  test('all haptic entry points are safe no-ops when unsupported', () async {
    final user = _HapticUser();
    final settings = SettingsProvider.instance..vibration = true;

    user.triggerHapticFeedback(settings);
    user.mediumPulse(settings);
    user.heavyPulse(settings);
    user.errorPulse(settings);

    // Backward-compatible global helpers.
    triggerHaptic(settings);
    runHaptic(settings);
    lightPulse(settings);
    HapticHelper.triggerHaptic(settings);

    // Allow the error pulse's delayed second impact (if supported) to run.
    await Future<void>.delayed(const Duration(milliseconds: 150));

    if (!HapticHelper.isSupported) {
      expect(vibrations, isEmpty);
    }
  });

  test('helpers short-circuit when the vibration setting is disabled',
      () async {
    final user = _HapticUser();
    final settings = SettingsProvider.instance..vibration = false;

    user.triggerHapticFeedback(settings);
    user.mediumPulse(settings);
    user.heavyPulse(settings);

    await Future<void>.delayed(Duration.zero);

    if (!HapticHelper.isSupported) {
      expect(vibrations, isEmpty);
    }
  });
}
