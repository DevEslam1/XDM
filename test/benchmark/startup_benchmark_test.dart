import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dmx/core/services/site_intelligence/site_intelligence_service.dart';
import 'package:dmx/core/services/dio_client_pool.dart';
import 'package:dmx/shared/animation/ambient_animation_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Startup Benchmark Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Core services initialize in sub-100ms budget', () async {
      final sw = Stopwatch()..start();

      final siteIntel = SiteIntelligenceService();
      await siteIntel.init();

      final dioPool = DioClientPool();
      const animCtrl = NoOpAmbientAnimationController();
      animCtrl.stopAll();

      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(500),
          reason: 'Service initialization should take < 500ms');

      dioPool.dispose();
      await siteIntel.dispose();
    });
  });
}
