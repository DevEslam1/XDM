import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/subscription/subscription_plan.dart';
import '../logging_service.dart';
import 'sub_club_api_client.dart';
import 'subscription_service.dart';

/// Result of a purchase attempt.
class PurchaseResult {
  final bool success;
  final String? receipt;
  final String? error;
  final SubscriptionPlan? plan;

  const PurchaseResult({
    required this.success,
    this.receipt,
    this.error,
    this.plan,
  });

  const PurchaseResult.success(String this.receipt, {this.plan})
      : success = true,
        error = null;

  const PurchaseResult.failure(String this.error)
      : success = false,
        receipt = null,
        plan = null;

  const PurchaseResult.cancelled()
      : success = false,
        receipt = null,
        error = 'Purchase was cancelled',
        plan = null;
}

/// Manages the in-app purchase flow.
///
/// Handles initiating purchases, listening to purchase updates,
/// restoring purchases, and sending receipts to Sub Club for validation.
///
/// This service is platform-aware and works with both iOS (StoreKit)
/// and Android (Google Play Billing) via the appropriate platform channels.
class PurchaseService extends ChangeNotifier {
  PurchaseService({
    required SubscriptionService subscriptionService,
    SubClubApiClient? apiClient,
  })  : _subscriptionService = subscriptionService,
        _apiClient = apiClient ?? SubClubApiClient();

  final SubscriptionService _subscriptionService;
  final SubClubApiClient _apiClient;
  final _log = LoggingService.logger('PurchaseService');

  StreamSubscription<List<Map<String, dynamic>>>? _purchaseSubscription;
  final _pendingPurchases = <String, Completer<PurchaseResult>>{};

  bool _isInitialized = false;
  bool _isPurchasing = false;

  bool get isPurchasing => _isPurchasing;

  /// Initializes the purchase flow and restores any existing purchases.
  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    try {
      // Listen for purchase updates from the platform
      // In production, this would be a MethodChannel or RevenueCat stream
      _log.info('Purchase service initialized');
    } catch (e, st) {
      _log.warning('Failed to initialize purchase service', e, st);
    }
  }

  /// Initiates a purchase for the given plan.
  ///
  /// Returns a [PurchaseResult] that completes when the purchase
  /// succeeds, fails, or is cancelled by the user.
  Future<PurchaseResult> purchase(SubscriptionPlan plan) async {
    if (_isPurchasing) {
      return const PurchaseResult.failure('A purchase is already in progress');
    }

    _isPurchasing = true;
    notifyListeners();

    final completer = Completer<PurchaseResult>();
    _pendingPurchases[plan.productId] = completer;

    try {
      _log.info('Initiating purchase for ${plan.id} (${plan.productId})');

      // In production: trigger platform-specific purchase flow
      // For now, simulate the flow
      await _initiatePlatformPurchase(plan);

      // Wait for the purchase to complete or timeout
      final result = await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          _pendingPurchases.remove(plan.productId);
          return const PurchaseResult.failure('Purchase timed out');
        },
      );

      if (result.success && result.receipt != null) {
        // Send receipt to Sub Club for validation
        _subscriptionService.setReceipt(result.receipt!);
      }

      return result;
    } catch (e, st) {
      _log.warning('Purchase failed', e, st);
      return PurchaseResult.failure(e.toString());
    } finally {
      _pendingPurchases.remove(plan.productId);
      _isPurchasing = false;
      notifyListeners();
    }
  }

  /// Restores previous purchases on a new device.
  Future<bool> restorePurchases() async {
    try {
      _log.info('Restoring purchases...');
      // In production: get platform-specific restore token
      final accountToken = 'restore_${DateTime.now().millisecondsSinceEpoch}';
      final success = await _subscriptionService.restorePurchases(
        accountToken: accountToken,
      );
      _log.info('Restore ${success ? 'succeeded' : 'failed'}');
      return success;
    } catch (e, st) {
      _log.warning('Restore failed', e, st);
      return false;
    }
  }

  /// Checks if a product is available for purchase.
  Future<bool> isProductAvailable(String productId) async {
    try {
      // In production: query platform store for product availability
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Gets the localized price for a product from the store.
  Future<String?> getProductPrice(String productId) async {
    try {
      // In production: query platform store for product price
      return SubscriptionPlan.all
          .where((p) => p.productId == productId)
          .map((p) => p.price)
          .firstOrNull;
    } catch (e) {
      return null;
    }
  }

  @override
  void dispose() {
    _purchaseSubscription?.cancel();
    // Complete any pending purchases as cancelled
    for (final completer in _pendingPurchases.values) {
      if (!completer.isCompleted) {
        completer.complete(const PurchaseResult.cancelled());
      }
    }
    _pendingPurchases.clear();
    _apiClient.dispose();
    super.dispose();
  }

  // ── Private ──

  Future<void> _initiatePlatformPurchase(SubscriptionPlan plan) async {
    // Platform-specific purchase implementation:
    //
    // iOS: StoreKit 2 via MethodChannel or RevenueCat
    // Android: Google Play Billing via MethodChannel or RevenueCat
    //
    // The platform side would:
    // 1. Query the store for the product
    // 2. Present the purchase dialog
    // 3. Return the receipt on success
    // 4. Call _completePurchase() with the result
    //
    // For now, this is a placeholder that will be connected to
    // the native side during integration.

    _log.info('Platform purchase initiated for ${plan.productId}');
  }

  /// Called by the platform purchase listener when a purchase completes.
  @visibleForTesting
  void completePurchase({
    required String productId,
    required bool success,
    String? receipt,
    String? error,
  }) {
    final completer = _pendingPurchases[productId];
    if (completer == null || completer.isCompleted) return;

    if (success && receipt != null) {
      completer.complete(PurchaseResult.success(receipt,
          plan: SubscriptionPlan.all
              .firstWhere((p) => p.productId == productId)));
    } else {
      completer.complete(PurchaseResult.failure(error ?? 'Unknown error'));
    }
  }

  /// Called by the platform when a purchase is cancelled.
  @visibleForTesting
  void cancelPurchase(String productId) {
    final completer = _pendingPurchases[productId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(const PurchaseResult.cancelled());
    }
  }
}
