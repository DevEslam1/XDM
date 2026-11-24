import 'package:dmx/core/domain/subscription/subscription_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SubscriptionStatus', () {
    test('getters per value', () {
      expect(SubscriptionStatus.free.isPremium, isFalse);
      expect(SubscriptionStatus.active.isPremium, isTrue);
      expect(SubscriptionStatus.trial.isPremium, isTrue);
      expect(SubscriptionStatus.expired.isPremium, isFalse);
      expect(SubscriptionStatus.cancelled.isPremium, isFalse);
      expect(SubscriptionStatus.unknown.isPremium, isFalse);

      expect(SubscriptionStatus.free.isFree, isTrue);
      expect(SubscriptionStatus.active.isFree, isFalse);

      expect(SubscriptionStatus.unknown.canDownload, isFalse);
      expect(SubscriptionStatus.free.canDownload, isTrue);
      expect(SubscriptionStatus.expired.canDownload, isTrue);

      expect(SubscriptionStatus.expired.inGracePeriod, isTrue);
      expect(SubscriptionStatus.free.inGracePeriod, isFalse);
    });

    test('has expected values', () {
      expect(SubscriptionStatus.values, hasLength(6));
    });
  });
}
