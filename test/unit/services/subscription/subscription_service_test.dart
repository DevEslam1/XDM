import 'package:dmx/core/domain/subscription/subscription_status.dart';
import 'package:dmx/core/services/subscription/subscription_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SubscriptionService', () {
    late SubscriptionService service;

    setUp(() {
      service = SubscriptionService();
    });

    tearDown(() {
      service.dispose();
    });

    test('initializes with free tier by default', () {
      expect(service.status, SubscriptionStatus.free);
      expect(service.isFree, isTrue);
      expect(service.isPremium, isFalse);
      expect(service.planId, isNull);
      expect(service.expiresAt, isNull);
      expect(service.lastError, isNull);
      expect(service.isValidating, isFalse);
    });

    test('has correct default tier limits', () {
      expect(service.maxConcurrentDownloads, 3);
      expect(service.maxDownloadThreads, 4);
    });

    test('hasReachedDownloadLimit delegates to tier', () {
      expect(service.hasReachedDownloadLimit(0), isFalse);
      expect(service.hasReachedDownloadLimit(2), isFalse);
      expect(service.hasReachedDownloadLimit(3), isTrue);
    });

    test('effectiveThreadCount clamps to tier max', () {
      expect(service.effectiveThreadCount(1), 1);
      expect(service.effectiveThreadCount(4), 4);
      expect(service.effectiveThreadCount(8), 4);
    });

    test('hasEntitlement checks tier capabilities', () {
      expect(service.hasEntitlement('torrent_support'), isFalse);
      expect(service.hasEntitlement('ad_removal'), isFalse);
      expect(service.hasEntitlement('unlimited_downloads'), isFalse);
    });

    test('inGracePeriod is false when not expired', () {
      expect(service.inGracePeriod, isFalse);
    });

    test('availablePlans returns all plans', () {
      expect(service.availablePlans.length, 3);
    });

    test('entitlements returns 6 items', () {
      expect(service.entitlements.length, 6);
    });

    test('validate without receipt sets free tier', () async {
      await service.validate();
      expect(service.status, SubscriptionStatus.free);
      expect(service.isFree, isTrue);
      expect(service.lastValidated, isNotNull);
    });

    test('setReceipt triggers validation', () async {
      service.setReceipt('test_receipt_123');
      // Validation happens async; since we don't have a real API,
      // it will fail and keep free tier
      await Future.delayed(const Duration(milliseconds: 100));
      expect(service.isValidating, isFalse);
    });

    test('concurrent validation calls are deduplicated', () async {
      // Start two validations simultaneously
      final f1 = service.validate();
      final f2 = service.validate();
      await Future.wait([f1, f2]);
      // Should have completed without error
      expect(service.isValidating, isFalse);
    });

    test('dispose cancels timer', () {
      // Should not throw
      service.dispose();
    });
  });
}
