import 'package:dmx/core/domain/subscription/entitlement.dart';
import 'package:dmx/core/domain/subscription/subscription_plan.dart';
import 'package:dmx/core/domain/subscription/subscription_status.dart';
import 'package:dmx/core/domain/subscription/subscription_tier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SubscriptionStatus', () {
    test('isPremium returns true for active and trial', () {
      expect(SubscriptionStatus.active.isPremium, isTrue);
      expect(SubscriptionStatus.trial.isPremium, isTrue);
      expect(SubscriptionStatus.free.isPremium, isFalse);
      expect(SubscriptionStatus.expired.isPremium, isFalse);
      expect(SubscriptionStatus.cancelled.isPremium, isFalse);
      expect(SubscriptionStatus.unknown.isPremium, isFalse);
    });

    test('isFree returns true only for free', () {
      expect(SubscriptionStatus.free.isFree, isTrue);
      expect(SubscriptionStatus.active.isFree, isFalse);
      expect(SubscriptionStatus.expired.isFree, isFalse);
    });

    test('canDownload returns false only for unknown', () {
      expect(SubscriptionStatus.free.canDownload, isTrue);
      expect(SubscriptionStatus.active.canDownload, isTrue);
      expect(SubscriptionStatus.expired.canDownload, isTrue);
      expect(SubscriptionStatus.unknown.canDownload, isFalse);
    });

    test('inGracePeriod returns true only for expired', () {
      expect(SubscriptionStatus.expired.inGracePeriod, isTrue);
      expect(SubscriptionStatus.active.inGracePeriod, isFalse);
      expect(SubscriptionStatus.free.inGracePeriod, isFalse);
    });
  });

  group('SubscriptionTier', () {
    test('free tier has correct limits', () {
      expect(SubscriptionTier.free.maxConcurrentDownloads, 3);
      expect(SubscriptionTier.free.maxDownloadThreads, 4);
      expect(SubscriptionTier.free.torrentSupport, isFalse);
      expect(SubscriptionTier.free.adRemoval, isFalse);
      expect(SubscriptionTier.free.isFree, isTrue);
      expect(SubscriptionTier.free.isPremium, isFalse);
    });

    test('premium tier has unlimited limits', () {
      expect(SubscriptionTier.premium.maxConcurrentDownloads, 0);
      expect(SubscriptionTier.premium.maxDownloadThreads, 0);
      expect(SubscriptionTier.premium.torrentSupport, isTrue);
      expect(SubscriptionTier.premium.adRemoval, isTrue);
      expect(SubscriptionTier.premium.isPremium, isTrue);
      expect(SubscriptionTier.premium.isFree, isFalse);
    });

    test('forStatus returns premium for active and trial', () {
      expect(SubscriptionTier.forStatus(SubscriptionStatus.active),
          SubscriptionTier.premium);
      expect(SubscriptionTier.forStatus(SubscriptionStatus.trial),
          SubscriptionTier.premium);
    });

    test('forStatus returns free for free, expired, cancelled, unknown', () {
      expect(SubscriptionTier.forStatus(SubscriptionStatus.free),
          SubscriptionTier.free);
      expect(SubscriptionTier.forStatus(SubscriptionStatus.expired),
          SubscriptionTier.free);
      expect(SubscriptionTier.forStatus(SubscriptionStatus.cancelled),
          SubscriptionTier.free);
      expect(SubscriptionTier.forStatus(SubscriptionStatus.unknown),
          SubscriptionTier.free);
    });

    test('hasReachedDownloadLimit checks correctly', () {
      expect(SubscriptionTier.free.hasReachedDownloadLimit(0), isFalse);
      expect(SubscriptionTier.free.hasReachedDownloadLimit(2), isFalse);
      expect(SubscriptionTier.free.hasReachedDownloadLimit(3), isTrue);
      expect(SubscriptionTier.free.hasReachedDownloadLimit(5), isTrue);
      // Premium never reaches limit (0 = unlimited)
      expect(SubscriptionTier.premium.hasReachedDownloadLimit(100), isFalse);
    });

    test('effectiveThreadCount clamps to tier max', () {
      expect(SubscriptionTier.free.effectiveThreadCount(1), 1);
      expect(SubscriptionTier.free.effectiveThreadCount(4), 4);
      expect(SubscriptionTier.free.effectiveThreadCount(8), 4);
      expect(SubscriptionTier.free.effectiveThreadCount(16), 4);
      // Premium returns requested (0 = unlimited)
      expect(SubscriptionTier.premium.effectiveThreadCount(8), 8);
      expect(SubscriptionTier.premium.effectiveThreadCount(32), 32);
    });

    test('equality works by id', () {
      expect(SubscriptionTier.free, equals(SubscriptionTier.free));
      expect(SubscriptionTier.premium, equals(SubscriptionTier.premium));
      expect(SubscriptionTier.free == SubscriptionTier.premium, isFalse);
    });
  });

  group('SubscriptionPlan', () {
    test('all plans have required fields', () {
      for (final plan in SubscriptionPlan.all) {
        expect(plan.id.isNotEmpty, isTrue);
        expect(plan.productId.isNotEmpty, isTrue);
        expect(plan.displayName.isNotEmpty, isTrue);
        expect(plan.price.isNotEmpty, isTrue);
      }
    });

    test('annual plan is popular', () {
      expect(SubscriptionPlan.annual.isPopular, isTrue);
      expect(SubscriptionPlan.monthly.isPopular, isFalse);
      expect(SubscriptionPlan.lifetime.isPopular, isFalse);
    });

    test('product IDs follow naming convention', () {
      expect(SubscriptionPlan.monthly.productId, 'com.xdm.premium.monthly');
      expect(SubscriptionPlan.annual.productId, 'com.xdm.premium.annual');
      expect(SubscriptionPlan.lifetime.productId, 'com.xdm.premium.lifetime');
    });

    test('equality works by id', () {
      expect(SubscriptionPlan.monthly, equals(SubscriptionPlan.monthly));
      expect(SubscriptionPlan.annual, equals(SubscriptionPlan.annual));
      expect(SubscriptionPlan.monthly == SubscriptionPlan.annual, isFalse);
    });

    test('all list contains 3 plans', () {
      expect(SubscriptionPlan.all.length, 3);
    });
  });

  group('Entitlement', () {
    test('free tier has correct entitlements', () {
      final entitlements = Entitlement.forTier(SubscriptionTier.free);
      expect(entitlements.length, 6);
      // Unlimited downloads disabled
      expect(
        entitlements
            .any((e) => e.key == 'unlimited_downloads' && e.isEnabled == false),
        isTrue,
      );
      // Torrent support disabled
      expect(
        entitlements
            .any((e) => e.key == 'torrent_support' && e.isEnabled == false),
        isTrue,
      );
      // Ad removal disabled
      expect(
        entitlements.any((e) => e.key == 'ad_removal' && e.isEnabled == false),
        isTrue,
      );
      // High thread count disabled (limited to 4)
      expect(
        entitlements
            .any((e) => e.key == 'high_thread_count' && e.isEnabled == false),
        isTrue,
      );
    });

    test('premium tier has all entitlements enabled', () {
      final entitlements = Entitlement.forTier(SubscriptionTier.premium);
      for (final entitlement in entitlements) {
        expect(entitlement.isEnabled, isTrue,
            reason:
                'Entitlement ${entitlement.key} should be enabled for premium');
        expect(entitlement.reason, isNull,
            reason:
                'Entitlement ${entitlement.key} should have no reason for premium');
      }
    });

    test('isEnabled checks correctly', () {
      expect(
          Entitlement.isEntitled(SubscriptionTier.premium, 'torrent_support'),
          isTrue);
      expect(Entitlement.isEntitled(SubscriptionTier.free, 'torrent_support'),
          isFalse);
      expect(
          Entitlement.isEntitled(
              SubscriptionTier.premium, 'unlimited_downloads'),
          isTrue);
      expect(
          Entitlement.isEntitled(SubscriptionTier.free, 'unlimited_downloads'),
          isFalse);
    });

    test('entitlements have reasons when disabled', () {
      final freeEntitlements = Entitlement.forTier(SubscriptionTier.free);
      for (final entitlement in freeEntitlements.where((e) => !e.isEnabled)) {
        expect(entitlement.reason, isNotNull);
        expect(entitlement.reason!.isNotEmpty, isTrue);
      }
    });
  });
}
