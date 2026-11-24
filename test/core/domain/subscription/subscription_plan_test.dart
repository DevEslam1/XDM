import 'package:dmx/core/domain/subscription/subscription_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SubscriptionPlan', () {
    test('predefined plans', () {
      expect(SubscriptionPlan.monthly.id, 'monthly');
      expect(SubscriptionPlan.monthly.isPopular, isFalse);
      expect(SubscriptionPlan.annual.id, 'annual');
      expect(SubscriptionPlan.annual.isPopular, isTrue);
      expect(SubscriptionPlan.lifetime.id, 'lifetime');
      expect(SubscriptionPlan.lifetime.period, '');
      expect(SubscriptionPlan.all, hasLength(3));
    });

    test('equality, hashCode and toString', () {
      const a = SubscriptionPlan(
        id: 'p',
        productId: 'pid',
        displayName: 'Plan',
        description: 'd',
        price: '\$1',
        period: '/mo',
      );
      const b = SubscriptionPlan(
        id: 'p',
        productId: 'other',
        displayName: 'Other',
        description: 'x',
        price: '\$9',
        period: '/yr',
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a == SubscriptionPlan.monthly, isFalse);
      expect(a == Object(), isFalse);
      expect(a.toString(), 'SubscriptionPlan(p, \$1/mo)');
    });
  });
}
