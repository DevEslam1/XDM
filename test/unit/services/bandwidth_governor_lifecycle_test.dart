import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BandwidthGovernor Consumer Lifecycle & Timer Management (P1-06)', () {
    late BandwidthGovernor governor;

    setUp(() {
      governor = BandwidthGovernor(1024 * 1024);
    });

    tearDown(() {
      governor.dispose();
    });

    test(
        'initial state does not start domain cleanup timer when consumers == 0',
        () {
      expect(governor.activeConsumers, equals(0));
      expect(governor.domainCleanupTimerForTesting, isNull);
    });

    test('registerConsumer starts domain cleanup timer on first consumer', () {
      governor.registerConsumer();
      expect(governor.activeConsumers, equals(1));
      expect(governor.domainCleanupTimerForTesting, isNotNull);
      expect(governor.domainCleanupTimerForTesting!.isActive, isTrue);

      final timer = governor.domainCleanupTimerForTesting;
      governor.registerConsumer();
      expect(governor.activeConsumers, equals(2));
      // Does not recreate or replace timer
      expect(governor.domainCleanupTimerForTesting, same(timer));
    });

    test(
        'unregisterConsumer cancels domain cleanup timer when consumers reach 0',
        () {
      governor.registerConsumer();
      governor.registerConsumer();
      expect(governor.domainCleanupTimerForTesting, isNotNull);

      governor.unregisterConsumer();
      expect(governor.activeConsumers, equals(1));
      expect(governor.domainCleanupTimerForTesting, isNotNull);

      governor.unregisterConsumer();
      expect(governor.activeConsumers, equals(0));
      expect(governor.domainCleanupTimerForTesting, isNull);
    });

    test('dispose cancels timer and clears domain state', () {
      governor.registerConsumer();
      expect(governor.domainCleanupTimerForTesting, isNotNull);

      governor.reportDomainSpeed('example.com', 5000.0);
      expect(governor.getAverageSpeedForDomain('example.com'), equals(5000.0));

      governor.dispose();
      expect(governor.domainCleanupTimerForTesting, isNull);
      expect(governor.getAverageSpeedForDomain('example.com'), equals(0.0));
    });
  });
}
