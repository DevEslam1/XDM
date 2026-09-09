import 'package:dmx/core/services/mirror_failover.dart';
import 'package:dmx/core/services/mirror_health_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await MirrorHealthStore.clear();
    await MirrorHealthStore.init();
  });

  group('MirrorFailover Circuit Breaker & Controlled Probing', () {
    test(
        'when all mirror circuits are open, advance probes least-bad alternative mirror',
        () async {
      const m1 = 'https://m1.com';
      const m2 = 'https://m2.com';
      const m3 = 'https://m3.com';

      // m1 (active) fails. m2 has 1 failure, m3 has 5 failures.
      for (var i = 0; i < 3; i++) {
        await MirrorHealthStore.recordFailure(m1);
      }
      await MirrorHealthStore.recordFailure(m2);
      for (var i = 0; i < 5; i++) {
        await MirrorHealthStore.recordFailure(m3);
      }

      final failover = MirrorFailover([m1, m2, m3]);

      // Trip circuits
      for (var i = 0; i < 3; i++) {
        failover.getCircuitForTesting(m1)?.recordFailure();
        failover.getCircuitForTesting(m2)?.recordFailure();
        failover.getCircuitForTesting(m3)?.recordFailure();
      }

      // advance from active m1 should pick m2 as the least-bad alternative
      final next = failover.advance();
      expect(next, isNotNull);
      expect(next, m2);
    });

    test('run with all circuits open probes least-bad mirror', () async {
      const m1 = 'https://m1.com';
      const m2 = 'https://m2.com';

      final failover = MirrorFailover([m1, m2]);
      final attempted = <String>[];

      // Fail m1 and m2 until circuits open
      await failover.run((url) async {
        throw Exception('simulated failure');
      });
      await failover.run((url) async {
        throw Exception('simulated failure');
      });
      await failover.run((url) async {
        throw Exception('simulated failure');
      });

      // Now run again; it should probe the least-bad candidate rather than silently dropping
      final result = await failover.run((url) async {
        attempted.add(url);
      });

      expect(attempted, isNotEmpty);
      expect(result, attempted.first);
    });

    test('successful probe clears failures and closes circuit', () async {
      const m = 'https://healthy.com';
      final failover = MirrorFailover([m]);

      // Record 3 failures to trip circuit
      for (var i = 0; i < 3; i++) {
        await MirrorHealthStore.recordFailure(m);
      }
      expect(MirrorHealthStore.getFailureCount(m), 3);

      // Run successful action
      final res = await failover.run((url) async {});
      expect(res, m);
      expect(MirrorHealthStore.getFailureCount(m), 0);
    });
  });
}
