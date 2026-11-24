import 'package:dmx/core/services/device_tier.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceCapabilities', () {
    test('derived flags reflect tier', () {
      const low = DeviceCapabilities(
        tier: DeviceTier.low,
        totalRamGb: 2,
        cores: 2,
      );
      const high = DeviceCapabilities(
        tier: DeviceTier.high,
        totalRamGb: 16,
        cores: 8,
      );
      expect(low.isLowEnd, isTrue);
      expect(low.isHighEnd, isFalse);
      expect(high.isHighEnd, isTrue);
      expect(high.isLowEnd, isFalse);
    });

    test('recommendedImageCacheMb clamps to 30..256', () {
      const tiny = DeviceCapabilities(
        tier: DeviceTier.low,
        totalRamGb: 1,
        cores: 2,
      );
      const huge = DeviceCapabilities(
        tier: DeviceTier.high,
        totalRamGb: 128,
        cores: 16,
      );
      expect(tiny.recommendedImageCacheMb, 30);
      expect(huge.recommendedImageCacheMb, 256);
    });

    test('recommendedImageCacheEntries clamps to 60..400', () {
      const tiny = DeviceCapabilities(
        tier: DeviceTier.low,
        totalRamGb: 1,
        cores: 2,
      );
      const huge = DeviceCapabilities(
        tier: DeviceTier.high,
        totalRamGb: 128,
        cores: 16,
      );
      expect(tiny.recommendedImageCacheEntries, 60);
      expect(huge.recommendedImageCacheEntries, 400);
    });

    test('recommendedIsolateCap maps by tier', () {
      expect(
        const DeviceCapabilities(
          tier: DeviceTier.low,
          totalRamGb: 2,
          cores: 2,
        ).recommendedIsolateCap,
        2,
      );
      expect(
        const DeviceCapabilities(
          tier: DeviceTier.balanced,
          totalRamGb: 4,
          cores: 4,
        ).recommendedIsolateCap,
        4,
      );
      expect(
        const DeviceCapabilities(
          tier: DeviceTier.high,
          totalRamGb: 16,
          cores: 8,
        ).recommendedIsolateCap,
        6,
      );
    });

    test('toString includes tier, ram and cores', () {
      const caps = DeviceCapabilities(
        tier: DeviceTier.balanced,
        totalRamGb: 4.5,
        cores: 4,
      );
      final s = caps.toString();
      expect(s, contains('balanced'));
      expect(s, contains('4.5'));
      expect(s, contains('cores: 4'));
    });
  });

  group('DeviceTierService', () {
    tearDown(DeviceTierService.resetForTesting);

    test('current falls back to balanced default before detect', () {
      DeviceTierService.resetForTesting();
      final current = DeviceTierService.current;
      expect(current.tier, DeviceTier.balanced);
      expect(current.totalRamGb, 4.0);
      expect(current.cores, 4);
    });

    test('setForTesting overrides current', () {
      DeviceTierService.setForTesting(
        const DeviceCapabilities(
          tier: DeviceTier.high,
          totalRamGb: 16,
          cores: 8,
        ),
      );
      expect(DeviceTierService.current.tier, DeviceTier.high);
    });

    test('detect returns a value and caches it', () async {
      DeviceTierService.resetForTesting();
      final first = await DeviceTierService.detect();
      expect(first.cores, greaterThan(0));
      // Second call returns the cached instance.
      final second = await DeviceTierService.detect();
      expect(identical(first, second), isTrue);
    });

    test('detect classifies host as a valid tier', () async {
      DeviceTierService.resetForTesting();
      final caps = await DeviceTierService.detect();
      expect(DeviceTier.values.contains(caps.tier), isTrue);
    });

    test('detect prefers the native total-memory bridge when present',
        () async {
      const channel = MethodChannel('com.dmx.app/device');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getTotalMemoryBytes') {
          return 16 * 1024 * 1024 * 1024;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      DeviceTierService.resetForTesting();
      final caps = await DeviceTierService.detect();
      expect(caps.totalRamGb, closeTo(16.0, 0.01));
    });

    test('detect falls back to platform heuristics when the bridge returns 0',
        () async {
      const channel = MethodChannel('com.dmx.app/device');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => 0);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      DeviceTierService.resetForTesting();
      final caps = await DeviceTierService.detect();
      expect(caps.totalRamGb, greaterThan(0));
      expect(caps.cores, greaterThan(0));
    });
  });
}
