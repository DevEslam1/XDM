import 'package:dmx/core/domain/subscription/subscription_status.dart';
import 'package:dmx/core/domain/subscription/subscription_tier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SubscriptionTier', () {
    test('free tier properties', () {
      const t = SubscriptionTier.free;
      expect(t.id, 'free');
      expect(t.displayName, 'Free');
      expect(t.maxConcurrentDownloads, 3);
      expect(t.maxDownloadThreads, 4);
      expect(t.torrentSupport, isFalse);
      expect(t.adRemoval, isFalse);
      expect(t.prioritySupport, isFalse);
      expect(t.unlimitedSpeed, isFalse);
      expect(t.isFree, isTrue);
      expect(t.isPremium, isFalse);
    });

    test('premium tier properties', () {
      const t = SubscriptionTier.premium;
      expect(t.id, 'premium');
      expect(t.maxConcurrentDownloads, 0);
      expect(t.maxDownloadThreads, 0);
      expect(t.torrentSupport, isTrue);
      expect(t.isPremium, isTrue);
      expect(t.isFree, isFalse);
    });

    test('forStatus maps each status', () {
      expect(SubscriptionTier.forStatus(SubscriptionStatus.active),
          SubscriptionTier.premium);
      expect(SubscriptionTier.forStatus(SubscriptionStatus.trial),
          SubscriptionTier.premium);
      expect(SubscriptionTier.forStatus(SubscriptionStatus.free),
          SubscriptionTier.free);
      expect(SubscriptionTier.forStatus(SubscriptionStatus.expired),
          SubscriptionTier.free);
      expect(SubscriptionTier.forStatus(SubscriptionStatus.cancelled),
          SubscriptionTier.free);
      expect(SubscriptionTier.forStatus(SubscriptionStatus.unknown),
          SubscriptionTier.free);
    });

    test('hasReachedDownloadLimit', () {
      expect(SubscriptionTier.free.hasReachedDownloadLimit(2), isFalse);
      expect(SubscriptionTier.free.hasReachedDownloadLimit(3), isTrue);
      expect(SubscriptionTier.free.hasReachedDownloadLimit(99), isTrue);
      expect(SubscriptionTier.premium.hasReachedDownloadLimit(9999), isFalse);
    });

    test('effectiveThreadCount', () {
      expect(SubscriptionTier.free.effectiveThreadCount(10), 4);
      expect(SubscriptionTier.free.effectiveThreadCount(2), 2);
      expect(SubscriptionTier.free.effectiveThreadCount(0), 1);
      expect(SubscriptionTier.premium.effectiveThreadCount(123), 123);
    });

    test('equality, hashCode and toString', () {
      expect(SubscriptionTier.free, equals(SubscriptionTier.free));
      expect(SubscriptionTier.free == SubscriptionTier.premium, isFalse);
      expect(SubscriptionTier.free == Object(), isFalse);
      expect(SubscriptionTier.free.hashCode, SubscriptionTier.free.hashCode);
      expect(SubscriptionTier.free.toString(), 'SubscriptionTier(free)');
    });
  });
}
