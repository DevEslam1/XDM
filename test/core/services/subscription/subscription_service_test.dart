import 'package:dmx/core/domain/subscription/subscription_status.dart';
import 'package:dmx/core/domain/subscription/subscription_tier.dart';
import 'package:dmx/core/services/subscription/sub_club_api_client.dart';
import 'package:dmx/core/services/subscription/subscription_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockSubClubApiClient extends Mock implements SubClubApiClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSubClubApiClient api;
  late SubscriptionService service;

  setUp(() {
    api = MockSubClubApiClient();
    service = SubscriptionService(apiClient: api);
  });

  tearDown(() {
    service.dispose();
  });

  group('SubscriptionService defaults', () {
    test('starts on the free tier with all expected defaults', () {
      expect(service.status, SubscriptionStatus.free);
      expect(service.tier, SubscriptionTier.free);
      expect(service.isPremium, isFalse);
      expect(service.isFree, isTrue);
      expect(service.isUnlocked, isFalse);
      expect(service.isValidating, isFalse);
      expect(service.lastError, isNull);
      expect(service.expiresAt, isNull);
      expect(service.planId, isNull);
      expect(service.lastValidated, isNull);
      expect(service.inGracePeriod, isFalse);
      expect(service.gracePeriodRemaining, Duration.zero);
    });

    test('exposes plans, entitlements and tier limits', () {
      expect(service.availablePlans, isNotEmpty);
      expect(service.entitlements, isNotEmpty);
      expect(service.maxConcurrentDownloads, 3);
      expect(service.maxDownloadThreads, 4);
      expect(service.hasReachedDownloadLimit(2), isFalse);
      expect(service.hasReachedDownloadLimit(3), isTrue);
      expect(service.effectiveThreadCount(8), 4);
    });

    test('toString reports status and tier', () {
      expect(service.toString(), contains('free'));
    });
  });

  group('SubscriptionService unlocked mode', () {
    test('unlocked constructor immediately applies the premium tier', () {
      final unlocked = SubscriptionService(apiClient: api, unlocked: true);
      addTearDown(unlocked.dispose);

      expect(unlocked.isUnlocked, isTrue);
      expect(unlocked.isPremium, isTrue);
      expect(unlocked.status, SubscriptionStatus.active);
      expect(unlocked.tier, SubscriptionTier.premium);
      expect(unlocked.planId, SubscriptionTier.premium.id);
      expect(unlocked.lastValidated, isNotNull);
    });

    test('validate is a no-op when unlocked', () async {
      final unlocked = SubscriptionService(apiClient: api, unlocked: true);
      addTearDown(unlocked.dispose);

      await unlocked.validate();
      verifyNever(() => api.validateReceipt(any()));
    });

    test('restorePurchases returns true without hitting the network', () async {
      final unlocked = SubscriptionService(apiClient: api, unlocked: true);
      addTearDown(unlocked.dispose);

      expect(
        await unlocked.restorePurchases(accountToken: 'tok'),
        isTrue,
      );
      verifyNever(() => api.restorePurchases(
            platform: any(named: 'platform'),
            accountToken: any(named: 'accountToken'),
          ));
    });

    test('setReceipt is ignored while unlocked', () {
      final unlocked = SubscriptionService(apiClient: api, unlocked: true);
      addTearDown(unlocked.dispose);

      unlocked.setReceipt('receipt');
      verifyNever(() => api.validateReceipt(any()));
    });
  });

  group('SubscriptionService.validate', () {
    test('without a receipt falls back to the free tier', () async {
      await service.validate();

      expect(service.status, SubscriptionStatus.free);
      expect(service.tier, SubscriptionTier.free);
      expect(service.lastValidated, isNotNull);
      verifyNever(() => api.validateReceipt(any()));
    });

    test('setReceipt is a no-op while purchases are disabled', () {
      service.setReceipt('receipt');
      verifyNever(() => api.validateReceipt(any()));
      expect(service.status, SubscriptionStatus.free);
    });
  });

  group('SubscriptionService.restorePurchases', () {
    test('maps an active response to premium and returns true', () async {
      when(() => api.restorePurchases(
            platform: any(named: 'platform'),
            accountToken: any(named: 'accountToken'),
          )).thenAnswer((_) async => const SubClubValidationResponse(
            status: SubscriptionStatus.active,
            expiresAt: '2030-01-01T00:00:00.000Z',
            planId: 'monthly',
          ));

      final ok = await service.restorePurchases(accountToken: 'token-1');

      expect(ok, isTrue);
      expect(service.status, SubscriptionStatus.active);
      expect(service.tier, SubscriptionTier.premium);
      expect(service.planId, 'monthly');
      expect(service.expiresAt, DateTime.parse('2030-01-01T00:00:00.000Z'));
      expect(service.lastValidated, isNotNull);
    });

    test('maps a non-premium response and returns false', () async {
      when(() => api.restorePurchases(
            platform: any(named: 'platform'),
            accountToken: any(named: 'accountToken'),
          )).thenAnswer((_) async => const SubClubValidationResponse(
            status: SubscriptionStatus.expired,
          ));

      final ok = await service.restorePurchases(accountToken: 'token-2');

      expect(ok, isFalse);
      expect(service.status, SubscriptionStatus.expired);
      expect(service.tier, SubscriptionTier.free);
      expect(service.expiresAt, isNull);
    });

    test('returns false when the API throws', () async {
      when(() => api.restorePurchases(
            platform: any(named: 'platform'),
            accountToken: any(named: 'accountToken'),
          )).thenThrow(StateError('network down'));

      expect(await service.restorePurchases(accountToken: 'x'), isFalse);
    });
  });

  group('SubscriptionService grace period', () {
    test('inGracePeriod is true once the subscription has expired', () async {
      when(() => api.restorePurchases(
            platform: any(named: 'platform'),
            accountToken: any(named: 'accountToken'),
          )).thenAnswer((_) async => const SubClubValidationResponse(
            status: SubscriptionStatus.expired,
            expiresAt: '2020-01-01T00:00:00.000Z',
          ));

      await service.restorePurchases(accountToken: 'x');

      expect(service.inGracePeriod, isTrue);
      expect(service.gracePeriodRemaining, Duration.zero);
    });
  });

  group('SubscriptionService.dispose', () {
    test('disposes the underlying api client', () {
      final localApi = MockSubClubApiClient();
      final local = SubscriptionService(apiClient: localApi);
      local.dispose();
      verify(() => localApi.dispose()).called(1);
    });
  });
}
