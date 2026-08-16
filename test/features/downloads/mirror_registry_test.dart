import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Mirror Registry & Benchmark Hardening (Sprint 2)', () {
    test('MirrorHealthStore coalesces dirty state and flushes', () async {
      final store = MirrorHealthStore();
      await store.init();

      await store.recordFailure('https://mirror1.example.com', statusCode: 503);
      expect(store.getFailureCount('https://mirror1.example.com'), equals(1));

      await store.flushPending(durable: true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mirror_health_data'), isNotNull);

      await store.clear();
    });
  });
}
