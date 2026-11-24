import 'package:dmx/core/domain/subscription/entitlement.dart';
import 'package:dmx/core/domain/subscription/subscription_tier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Entitlement', () {
    test('free tier entitlements are disabled with reasons', () {
      final list = Entitlement.forTier(SubscriptionTier.free);
      expect(list, hasLength(6));
      for (final e in list) {
        expect(e.isEnabled, isFalse);
        expect(e.reason, isNotNull);
      }
      final thread = list.firstWhere((e) => e.key == 'high_thread_count');
      expect(thread.reason, contains('4'));
    });

    test('premium tier entitlements are enabled without reasons', () {
      final list = Entitlement.forTier(SubscriptionTier.premium);
      expect(list, hasLength(6));
      for (final e in list) {
        expect(e.isEnabled, isTrue);
        expect(e.reason, isNull);
      }
    });

    test('isEntitled', () {
      expect(
        Entitlement.isEntitled(SubscriptionTier.premium, 'torrent_support'),
        isTrue,
      );
      expect(
        Entitlement.isEntitled(SubscriptionTier.free, 'torrent_support'),
        isFalse,
      );
      expect(
        Entitlement.isEntitled(SubscriptionTier.free, 'nonexistent'),
        isFalse,
      );
    });

    test('toString', () {
      final e = Entitlement.forTier(SubscriptionTier.free).first;
      expect(e.toString(), contains('Entitlement'));
      expect(e.toString(), contains(e.key));
    });
  });
}
