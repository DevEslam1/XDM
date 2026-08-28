import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/subscription/entitlement.dart';
import '../../domain/subscription/subscription_plan.dart';
import '../../domain/subscription/subscription_status.dart';
import '../../domain/subscription/subscription_tier.dart';
import '../logging_service.dart';
import 'sub_club_api_client.dart';

/// Core subscription service managing subscription state, caching,
/// and feature gating across the app.
///
/// This service is the single source of truth for subscription state.
/// It caches the last-known status locally and revalidates with the
/// Sub Club server on app start and periodically while active.
class SubscriptionService extends ChangeNotifier {
  SubscriptionService({
    SubClubApiClient? apiClient,
    this.validationInterval = const Duration(minutes: 30),
  }) : _apiClient = apiClient ?? SubClubApiClient();

  final SubClubApiClient _apiClient;
  final Duration validationInterval;

  final _log = LoggingService.logger('SubscriptionService');

  // ── State ──
  SubscriptionStatus _status = SubscriptionStatus.free;
  SubscriptionTier _tier = SubscriptionTier.free;
  String? _receipt;
  DateTime? _lastValidated;
  DateTime? _expiresAt;
  String? _planId;
  bool _isValidating = false;
  String? _lastError;
  Timer? _validationTimer;

  // ── Public getters ──
  SubscriptionStatus get status => _status;
  SubscriptionTier get tier => _tier;
  bool get isPremium => _status.isPremium;
  bool get isFree => _status.isFree;
  bool get isValidating => _isValidating;
  String? get lastError => _lastError;
  DateTime? get expiresAt => _expiresAt;
  String? get planId => _planId;
  DateTime? get lastValidated => _lastValidated;

  /// All available plans for upgrade.
  List<SubscriptionPlan> get availablePlans => SubscriptionPlan.all;

  /// Current entitlements based on tier.
  List<Entitlement> get entitlements => Entitlement.forTier(_tier);

  /// Whether a specific entitlement is active.
  bool hasEntitlement(String key) => Entitlement.isEntitled(_tier, key);

  /// Max concurrent downloads for current tier.
  int get maxConcurrentDownloads => _tier.maxConcurrentDownloads;

  /// Max download threads for current tier.
  int get maxDownloadThreads => _tier.maxDownloadThreads;

  /// Whether the user has reached the download limit.
  bool hasReachedDownloadLimit(int activeCount) {
    return _tier.hasReachedDownloadLimit(activeCount);
  }

  /// Effective thread count clamped to tier limits.
  int effectiveThreadCount(int requested) {
    return _tier.effectiveThreadCount(requested);
  }

  /// Whether the subscription is in a grace period after expiry.
  bool get inGracePeriod => _status == SubscriptionStatus.expired;

  /// Remaining grace period duration (default 24 hours).
  Duration get gracePeriodRemaining {
    if (_expiresAt == null) return Duration.zero;
    final graceEnd = _expiresAt!.add(const Duration(hours: 24));
    final remaining = graceEnd.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  // ── Lifecycle ──

  /// Initializes the service and starts periodic validation.
  Future<void> init({String? receipt}) async {
    if (receipt != null) {
      _receipt = receipt;
    }
    await _loadCachedStatus();
    await validate();
    _startPeriodicValidation();
  }

  /// Validates the current receipt against the Sub Club server.
  Future<void> validate() async {
    if (_isValidating) return;
    if (_receipt == null) {
      _log.fine('No receipt to validate — defaulting to free tier');
      _setFreeTier();
      return;
    }

    _isValidating = true;
    _lastError = null;
    notifyListeners();

    try {
      final response = await _apiClient.validateReceipt(_receipt!);
      _status = response.status;
      _tier = SubscriptionTier.forStatus(response.status);
      _expiresAt = response.expiresAt != null
          ? DateTime.tryParse(response.expiresAt!)
          : null;
      _planId = response.planId;
      _lastValidated = DateTime.now();

      _log.info('Subscription validated: $_status (plan=$_planId)');
      await _cacheStatus();
    } catch (e, st) {
      _log.warning('Subscription validation failed', e, st);
      _lastError = e.toString();
      // On failure, keep cached status — don't downgrade
    } finally {
      _isValidating = false;
      notifyListeners();
    }
  }

  /// Restores purchases on a new device.
  Future<bool> restorePurchases({required String accountToken}) async {
    try {
      final platform =
          defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
      final response = await _apiClient.restorePurchases(
        platform: platform,
        accountToken: accountToken,
      );
      _status = response.status;
      _tier = SubscriptionTier.forStatus(response.status);
      _expiresAt = response.expiresAt != null
          ? DateTime.parse(response.expiresAt!)
          : null;
      _planId = response.planId;
      _lastValidated = DateTime.now();

      await _cacheStatus();
      notifyListeners();
      return _status.isPremium;
    } catch (e, st) {
      _log.warning('Restore purchases failed', e, st);
      return false;
    }
  }

  /// Updates the receipt after a successful purchase.
  void setReceipt(String receipt) {
    _receipt = receipt;
    validate();
  }

  /// Disposes resources.
  @override
  void dispose() {
    _validationTimer?.cancel();
    _apiClient.dispose();
    super.dispose();
  }

  // ── Private ──

  void _setFreeTier() {
    _status = SubscriptionStatus.free;
    _tier = SubscriptionTier.free;
    _lastValidated = DateTime.now();
    notifyListeners();
  }

  void _startPeriodicValidation() {
    _validationTimer?.cancel();
    _validationTimer = Timer.periodic(validationInterval, (_) {
      validate();
    });
  }

  Future<void> _loadCachedStatus() async {
    try {
      // In production, load from SharedPreferences
      // For now, default to free
      _status = SubscriptionStatus.free;
      _tier = SubscriptionTier.free;
    } catch (e) {
      _log.fine('Failed to load cached subscription status: $e');
    }
  }

  Future<void> _cacheStatus() async {
    try {
      // In production, persist to SharedPreferences
      // This is a placeholder for the caching layer
    } catch (e) {
      _log.fine('Failed to cache subscription status: $e');
    }
  }

  @override
  String toString() =>
      'SubscriptionService(status=$_status, tier=$_tier, plan=$_planId)';
}
