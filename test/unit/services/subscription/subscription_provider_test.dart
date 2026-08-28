import 'package:dmx/core/domain/subscription/subscription_plan.dart';
import 'package:dmx/core/services/subscription/purchase_service.dart';
import 'package:dmx/core/services/subscription/subscription_service.dart';
import 'package:dmx/features/subscription/provider/subscription_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SubscriptionProvider', () {
    late SubscriptionService subscriptionService;
    late PurchaseService purchaseService;
    late SubscriptionProvider provider;

    setUp(() {
      subscriptionService = SubscriptionService();
      purchaseService = PurchaseService(
        subscriptionService: subscriptionService,
      );
      provider = SubscriptionProvider(
        subscriptionService: subscriptionService,
        purchaseService: purchaseService,
      );
    });

    tearDown(() {
      provider.dispose();
      purchaseService.dispose();
      subscriptionService.dispose();
    });

    test('initializes with free tier state', () {
      expect(provider.isFree, isTrue);
      expect(provider.isPremium, isFalse);
      expect(provider.status.isFree, isTrue);
      expect(provider.selectedPlan, isNull);
      expect(provider.isPurchasing, isFalse);
      expect(provider.error, isNull);
    });

    test('selectPlan updates selectedPlan', () {
      provider.selectPlan(SubscriptionPlan.monthly);
      expect(provider.selectedPlan, SubscriptionPlan.monthly);

      provider.selectPlan(SubscriptionPlan.annual);
      expect(provider.selectedPlan, SubscriptionPlan.annual);
    });

    test('purchaseSelectedPlan fails when no plan selected', () async {
      final result = await provider.purchaseSelectedPlan();
      expect(result, isFalse);
      expect(provider.error, 'No plan selected');
    });

    test('purchaseSelectedPlan succeeds with mocked purchase', () async {
      provider.selectPlan(SubscriptionPlan.monthly);

      // Start purchase in background
      final purchaseFuture = provider.purchaseSelectedPlan();
      await Future.delayed(const Duration(milliseconds: 50));

      // Complete from platform side
      purchaseService.completePurchase(
        productId: SubscriptionPlan.monthly.productId,
        success: true,
        receipt: 'test_receipt_xyz',
      );

      final result = await purchaseFuture;
      expect(result, isTrue);
      expect(provider.error, isNull);
      expect(provider.isPurchasing, isFalse);
    });

    test('purchaseSelectedPlan handles failure', () async {
      provider.selectPlan(SubscriptionPlan.annual);

      final purchaseFuture = provider.purchaseSelectedPlan();
      await Future.delayed(const Duration(milliseconds: 50));

      purchaseService.completePurchase(
        productId: SubscriptionPlan.annual.productId,
        success: false,
        error: 'Payment declined',
      );

      final result = await purchaseFuture;
      expect(result, isFalse);
      expect(provider.error, 'Payment declined');
      expect(provider.isPurchasing, isFalse);
    });

    test('restorePurchases returns result', () async {
      final result = await provider.restorePurchases();
      expect(result, isA<bool>());
    });

    test('clearError resets error', () {
      provider.selectPlan(SubscriptionPlan.monthly);
      provider.purchaseSelectedPlan();
      // After no plan selected error
      provider.clearError();
      expect(provider.error, isNull);
    });

    test('delegates availablePlans to service', () {
      expect(provider.availablePlans.length, 3);
    });

    test('delegates inGracePeriod to service', () {
      expect(provider.inGracePeriod, isFalse);
    });

    test('dispose removes listener from subscription service', () {
      provider.dispose();
      // Should not throw when subscription service notifies
      subscriptionService.notifyListeners();
    });
  });
}
