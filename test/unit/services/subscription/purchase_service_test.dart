import 'package:dmx/core/domain/subscription/subscription_plan.dart';
import 'package:dmx/core/services/subscription/purchase_service.dart';
import 'package:dmx/core/services/subscription/subscription_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PurchaseResult', () {
    test('success constructor', () {
      const result = PurchaseResult.success('receipt_123');
      expect(result.success, isTrue);
      expect(result.receipt, 'receipt_123');
      expect(result.error, isNull);
    });

    test('failure constructor', () {
      const result = PurchaseResult.failure('payment declined');
      expect(result.success, isFalse);
      expect(result.receipt, isNull);
      expect(result.error, 'payment declined');
    });

    test('cancelled constructor', () {
      const result = PurchaseResult.cancelled();
      expect(result.success, isFalse);
      expect(result.receipt, isNull);
      expect(result.error, 'Purchase was cancelled');
    });
  });

  group('PurchaseService', () {
    late SubscriptionService subscriptionService;
    late PurchaseService purchaseService;

    setUp(() {
      subscriptionService = SubscriptionService();
      purchaseService = PurchaseService(
        subscriptionService: subscriptionService,
      );
    });

    tearDown(() async {
      await Future.delayed(Duration.zero);
      purchaseService.dispose();
      subscriptionService.dispose();
    });

    test('initializes with no purchase in progress', () {
      expect(purchaseService.isPurchasing, isFalse);
    });

    test('init does not throw', () async {
      await purchaseService.init();
    });

    test('double init is idempotent', () async {
      await purchaseService.init();
      await purchaseService.init();
      expect(purchaseService.isPurchasing, isFalse);
    });

    test('completePurchase resolves pending purchase', () async {
      final purchaseFuture = purchaseService.purchase(SubscriptionPlan.monthly);

      await Future.delayed(const Duration(milliseconds: 100));

      purchaseService.completePurchase(
        productId: SubscriptionPlan.monthly.productId,
        success: true,
        receipt: 'test_receipt_abc',
      );

      final result = await purchaseFuture.timeout(const Duration(seconds: 5));
      expect(result.success, isTrue);
      expect(result.receipt, 'test_receipt_abc');
    });

    test('cancelPurchase resolves as cancelled', () async {
      final purchaseFuture = purchaseService.purchase(SubscriptionPlan.annual);
      await Future.delayed(const Duration(milliseconds: 100));

      purchaseService.cancelPurchase(SubscriptionPlan.annual.productId);

      final result = await purchaseFuture.timeout(const Duration(seconds: 5));
      expect(result.success, isFalse);
      expect(result.error, 'Purchase was cancelled');
    });

    test('restorePurchases does not throw', () async {
      final result = await purchaseService.restorePurchases();
      expect(result, isA<bool>());
    });

    test('getProductPrice returns price for valid product', () async {
      final price = await purchaseService
          .getProductPrice(SubscriptionPlan.monthly.productId);
      expect(price, '\$4.99');
    });

    test('getProductPrice returns null for unknown product', () async {
      final price = await purchaseService.getProductPrice('unknown.product');
      expect(price, isNull);
    });

    test('isProductAvailable returns true', () async {
      final available = await purchaseService
          .isProductAvailable(SubscriptionPlan.monthly.productId);
      expect(available, isTrue);
    });

    test('dispose cancels pending purchases', () async {
      final purchaseFuture = purchaseService.purchase(SubscriptionPlan.monthly);
      await Future.delayed(const Duration(milliseconds: 100));

      purchaseService.dispose();

      final result = await purchaseFuture.timeout(const Duration(seconds: 5));
      expect(result.success, isFalse);
      expect(result.error, 'Purchase was cancelled');
    });
  });
}
