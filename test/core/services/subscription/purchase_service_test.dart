import 'dart:async';

import 'package:dmx/core/domain/subscription/subscription_plan.dart';
import 'package:dmx/core/services/subscription/purchase_service.dart';
import 'package:dmx/core/services/subscription/subscription_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockSubscriptionService extends Mock implements SubscriptionService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSubscriptionService subscription;
  late PurchaseService purchase;

  setUp(() {
    subscription = MockSubscriptionService();
    purchase = PurchaseService(
      subscriptionService: subscription,
      platformPurchaseInitiator: (_) async => true,
    );
  });

  tearDown(() {
    purchase.dispose();
  });

  group('PurchaseResult constructors', () {
    test('base constructor carries all fields', () {
      const r = PurchaseResult(
        success: true,
        receipt: 'r',
        error: null,
        plan: SubscriptionPlan.monthly,
      );
      expect(r.success, isTrue);
      expect(r.receipt, 'r');
      expect(r.error, isNull);
      expect(r.plan, SubscriptionPlan.monthly);
    });

    test('success carries the receipt and optional plan', () {
      const r = PurchaseResult.success('rcpt', plan: SubscriptionPlan.monthly);
      expect(r.success, isTrue);
      expect(r.receipt, 'rcpt');
      expect(r.error, isNull);
      expect(r.plan, SubscriptionPlan.monthly);
    });

    test('failure carries the error', () {
      const r = PurchaseResult.failure('nope');
      expect(r.success, isFalse);
      expect(r.receipt, isNull);
      expect(r.plan, isNull);
      expect(r.error, 'nope');
    });

    test('cancelled is a fixed failure', () {
      const r = PurchaseResult.cancelled();
      expect(r.success, isFalse);
      expect(r.receipt, isNull);
      expect(r.plan, isNull);
      expect(r.error, 'Purchase was cancelled');
    });
  });

  group('PurchaseService basics', () {
    test('init is idempotent', () async {
      await purchase.init();
      await purchase.init();
      expect(purchase.isPurchasing, isFalse);
    });

    test('isProductAvailable returns true', () async {
      expect(
        await purchase.isProductAvailable(SubscriptionPlan.monthly.productId),
        isTrue,
      );
    });

    test('getProductPrice resolves known products and null otherwise',
        () async {
      expect(
        await purchase.getProductPrice(SubscriptionPlan.annual.productId),
        SubscriptionPlan.annual.price,
      );
      expect(await purchase.getProductPrice('missing'), isNull);
    });
  });

  group('PurchaseService.purchase', () {
    test('fails when the platform cannot initiate billing', () async {
      final defaultService = PurchaseService(subscriptionService: subscription);
      addTearDown(defaultService.dispose);

      final result = await defaultService.purchase(SubscriptionPlan.monthly);
      expect(result.success, isFalse);
      expect(result.error, contains('not available'));
    });

    test('surfaces an exception thrown by the platform initiator', () async {
      final service = PurchaseService(
        subscriptionService: subscription,
        platformPurchaseInitiator: (_) async => throw StateError('boom'),
      );
      addTearDown(service.dispose);

      final result = await service.purchase(SubscriptionPlan.monthly);
      expect(result.success, isFalse);
      expect(result.error, contains('boom'));
    });

    test('rejects a second purchase while one is in progress', () async {
      final gate = Completer<bool>();
      final service = PurchaseService(
        subscriptionService: subscription,
        platformPurchaseInitiator: (_) => gate.future,
      );
      addTearDown(service.dispose);

      final first = service.purchase(SubscriptionPlan.monthly);
      await Future<void>.delayed(Duration.zero);

      final second = await service.purchase(SubscriptionPlan.annual);
      expect(second.success, isFalse);
      expect(second.error, 'A purchase is already in progress');

      gate.complete(true);
      await Future<void>.delayed(Duration.zero);
      service.completePurchase(
        productId: SubscriptionPlan.monthly.productId,
        success: true,
        receipt: 'rcpt',
      );
      await first;
    });

    test('fails when already disposed', () async {
      final service = PurchaseService(
        subscriptionService: subscription,
        platformPurchaseInitiator: (_) async => true,
      );
      service.dispose();
      final result = await service.purchase(SubscriptionPlan.monthly);
      expect(result.success, isFalse);
      expect(result.error, 'Purchase service was disposed');
    });

    test('completes successfully and forwards the receipt to the service',
        () async {
      final future = purchase.purchase(SubscriptionPlan.monthly);
      await Future<void>.delayed(Duration.zero);

      purchase.completePurchase(
        productId: SubscriptionPlan.monthly.productId,
        success: true,
        receipt: 'receipt-xyz',
      );

      final result = await future;
      expect(result.success, isTrue);
      expect(result.receipt, 'receipt-xyz');
      expect(result.plan, SubscriptionPlan.monthly);
      verify(() => subscription.setReceipt('receipt-xyz')).called(1);
    });

    test('completePurchase with success but no receipt is a failure', () async {
      final future = purchase.purchase(SubscriptionPlan.annual);
      await Future<void>.delayed(Duration.zero);

      purchase.completePurchase(
        productId: SubscriptionPlan.annual.productId,
        success: true,
      );

      final result = await future;
      expect(result.success, isFalse);
      expect(result.error, 'Unknown error');
    });

    test('completePurchase forwards an explicit error', () async {
      final future = purchase.purchase(SubscriptionPlan.annual);
      await Future<void>.delayed(Duration.zero);

      purchase.completePurchase(
        productId: SubscriptionPlan.annual.productId,
        success: false,
        error: 'declined',
      );

      final result = await future;
      expect(result.success, isFalse);
      expect(result.error, 'declined');
    });

    test('cancelPurchase resolves as cancelled', () async {
      final future = purchase.purchase(SubscriptionPlan.lifetime);
      await Future<void>.delayed(Duration.zero);

      purchase.cancelPurchase(SubscriptionPlan.lifetime.productId);

      final result = await future;
      expect(result.success, isFalse);
      expect(result.error, 'Purchase was cancelled');
    });

    test('completePurchase / cancelPurchase with no pending entry are no-ops',
        () {
      purchase.completePurchase(productId: 'nope', success: true, receipt: 'r');
      purchase.cancelPurchase('nope');
      expect(purchase.isPurchasing, isFalse);
    });

    test('times out after five minutes', () {
      fakeAsync((async) {
        final service = PurchaseService(
          subscriptionService: subscription,
          platformPurchaseInitiator: (_) async => true,
        );
        PurchaseResult? result;
        service.purchase(SubscriptionPlan.monthly).then((r) => result = r);
        async.elapse(const Duration(minutes: 6));

        expect(result, isNotNull);
        expect(result!.success, isFalse);
        expect(result!.error, 'Purchase timed out');
        service.dispose();
      });
    });
  });

  group('PurchaseService.restorePurchases', () {
    test('delegates to the subscription service', () async {
      when(() => subscription.restorePurchases(
            accountToken: any(named: 'accountToken'),
          )).thenAnswer((_) async => true);

      expect(await purchase.restorePurchases(), isTrue);
    });

    test('returns false when restore throws', () async {
      when(() => subscription.restorePurchases(
            accountToken: any(named: 'accountToken'),
          )).thenThrow(StateError('boom'));

      expect(await purchase.restorePurchases(), isFalse);
    });
  });

  group('PurchaseService.dispose', () {
    test('resolves pending purchases as cancelled', () async {
      final future = purchase.purchase(SubscriptionPlan.monthly);
      await Future<void>.delayed(Duration.zero);

      purchase.dispose();

      final result = await future;
      expect(result.success, isFalse);
      expect(result.error, 'Purchase was cancelled');

      // Avoid double-dispose in tearDown.
      purchase = PurchaseService(subscriptionService: subscription);
    });
  });
}
