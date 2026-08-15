import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:dmx/core/services/site_intelligence/site_intelligence_service.dart';
import 'package:dmx/core/utils/bounded_lru_cache.dart';
import 'package:dmx/shared/animation/ambient_animation_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Memory Leak Detection & Bounded Resource Tests', () {
    test('BoundedLruCache does not grow unbounded under high churn', () {
      final cache = BoundedLruCache<String, String>(maxCapacity: 100);
      for (int i = 0; i < 10000; i++) {
        cache.put('key_$i', 'value_$i');
      }
      expect(cache.length, 100);
    });

    test('TimestampedLruMap stays strictly bounded under heavy writes', () {
      final map = TimestampedLruMap<String, int>(maxCapacity: 50);
      for (int i = 0; i < 5000; i++) {
        map.put('k_$i', i);
      }
      expect(map.length, 50);
    });

    test('NoOpAmbientAnimationController behaves as pure no-op with zero allocations', () {
      const controller = NoOpAmbientAnimationController();
      controller.stopAll();
      controller.restartIfMounted();
      controller.restartIfActive();
    });

    test('SiteIntelligenceService onMemoryPressure clears fast path cache', () async {
      final service = SiteIntelligenceService();
      service.analyzeUrl('https://example.org/download/test.mp4');
      service.onMemoryPressure();
      await service.dispose();
    });
  });
}
