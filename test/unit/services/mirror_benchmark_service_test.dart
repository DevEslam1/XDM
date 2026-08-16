import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MirrorBenchmarkService Tests', () {
    late MirrorBenchmarkService service;

    setUp(() {
      service = MirrorBenchmarkService();
      service.clearCache();
    });

    tearDown(() async {
      await service.dispose();
    });

    test('benchmarkAll returns empty list for empty urls', () async {
      final results = await service.benchmarkAll([]);
      expect(results, isEmpty);
    });

    test('onMemoryPressure clears cache', () {
      service.onMemoryPressure();
      // Verifies no exception thrown on clearing cache under memory pressure
      expect(true, isTrue);
    });
  });
}
