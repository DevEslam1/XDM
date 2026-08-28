import 'package:flutter/material.dart';

import '../../../core/domain/subscription/subscription_plan.dart';
import '../../../core/domain/subscription/subscription_status.dart';
import '../../../core/domain/subscription/subscription_tier.dart';
import '../../../core/services/subscription/purchase_service.dart';
import '../../../core/services/subscription/subscription_service.dart';

/// ViewModel for the subscription screen.
class SubscriptionProvider extends ChangeNotifier {
  SubscriptionProvider({
    required SubscriptionService subscriptionService,
    required PurchaseService purchaseService,
  })  : _subscriptionService = subscriptionService,
        _purchaseService = purchaseService {
    _subscriptionService.addListener(_onSubscriptionChanged);
  }

  final SubscriptionService _subscriptionService;
  final PurchaseService _purchaseService;

  SubscriptionPlan? _selectedPlan;
  bool _isPurchasing = false;
  String? _error;

  // ── Delegated getters ──
  SubscriptionStatus get status => _subscriptionService.status;
  SubscriptionTier get tier => _subscriptionService.tier;
  bool get isPremium => _subscriptionService.isPremium;
  bool get isFree => _subscriptionService.isFree;
  bool get isValidating => _subscriptionService.isValidating;
  bool get inGracePeriod => _subscriptionService.inGracePeriod;
  DateTime? get expiresAt => _subscriptionService.expiresAt;
  String? get planId => _subscriptionService.planId;
  List<SubscriptionPlan> get availablePlans =>
      _subscriptionService.availablePlans;
  bool get isPurchasing => _isPurchasing;
  String? get error => _error;
  SubscriptionPlan? get selectedPlan => _selectedPlan;

  bool get isAnnualBestValue => true;

  // ── Actions ──

  void selectPlan(SubscriptionPlan plan) {
    _selectedPlan = plan;
    notifyListeners();
  }

  Future<bool> purchaseSelectedPlan() async {
    final plan = _selectedPlan;
    if (plan == null) {
      _error = 'No plan selected';
      notifyListeners();
      return false;
    }

    _isPurchasing = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _purchaseService.purchase(plan);
      if (result.success) {
        _error = null;
        notifyListeners();
        return true;
      } else {
        _error = result.error;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    } finally {
      _isPurchasing = false;
      notifyListeners();
    }
  }

  Future<bool> restorePurchases() async {
    _error = null;
    notifyListeners();

    try {
      final success = await _purchaseService.restorePurchases();
      if (!success) {
        _error = 'No purchases to restore';
      }
      notifyListeners();
      return success;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void _onSubscriptionChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    _subscriptionService.removeListener(_onSubscriptionChanged);
    super.dispose();
  }
}
