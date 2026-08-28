import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/di/injection.dart';
import '../../../core/domain/subscription/subscription_status.dart';
import '../../../core/domain/subscription/subscription_tier.dart';
import '../../../core/utils/localization.dart';
import 'subscription_service.dart';

/// Mixin that provides subscription-aware guards for widgets.
///
/// Use this mixin on screens or widgets that need to check entitlements
/// before allowing certain actions.
mixin SubscriptionGuard<T extends StatefulWidget> on State<T> {
  SubscriptionService get subscriptionService => inject<SubscriptionService>();

  SubscriptionTier get currentTier => subscriptionService.tier;
  SubscriptionStatus get subscriptionStatus => subscriptionService.status;
  bool get isPremium => subscriptionService.isPremium;

  /// Checks if the user has a specific entitlement and shows an upgrade
  /// prompt if not.
  ///
  /// Returns `true` if the user has the entitlement, `false` if blocked.
  bool checkEntitlement(String entitlementKey, {String? featureName}) {
    if (subscriptionService.hasEntitlement(entitlementKey)) return true;

    _showUpgradePrompt(featureName ?? entitlementKey);
    return false;
  }

  /// Checks if the user has reached the concurrent download limit.
  ///
  /// Returns `true` if downloads are allowed, `false` if at limit.
  bool checkDownloadLimit(int activeCount) {
    if (!subscriptionService.hasReachedDownloadLimit(activeCount)) return true;

    _showDownloadLimitPrompt();
    return false;
  }

  void _showUpgradePrompt(String featureName) {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _UpgradeBottomSheet(
        featureName: featureName,
        subscriptionService: subscriptionService,
      ),
    );
  }

  void _showDownloadLimitPrompt() {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DownloadLimitBottomSheet(
        subscriptionService: subscriptionService,
      ),
    );
  }
}

class _UpgradeBottomSheet extends StatelessWidget {
  final String featureName;
  final SubscriptionService subscriptionService;

  const _UpgradeBottomSheet({
    required this.featureName,
    required this.subscriptionService,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.surface : AppTheme.lightSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          const Icon(
            Icons.lock_outline_rounded,
            size: 48,
            color: AppTheme.neonCyan,
          ),
          const SizedBox(height: 16),
          Text(
            L10n.of(context, 'subscription_premium_feature'),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            L10n.of(context, 'subscription_upgrade_to_unlock'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).pushNamed('/subscription');
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.neonCyan,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                L10n.of(context, 'subscription_view_plans'),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              L10n.of(context, 'maybe_later'),
              style: TextStyle(color: Colors.grey[400]),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _DownloadLimitBottomSheet extends StatelessWidget {
  final SubscriptionService subscriptionService;

  const _DownloadLimitBottomSheet({required this.subscriptionService});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final limit = subscriptionService.maxConcurrentDownloads;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.surface : AppTheme.lightSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          const Icon(
            Icons.download_done_rounded,
            size: 48,
            color: AppTheme.neonAmber,
          ),
          const SizedBox(height: 16),
          Text(
            L10n.of(context, 'subscription_max_downloads_reached'),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            L10n.of(context, 'subscription_free_limit', args: {'0': '$limit'}),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).pushNamed('/subscription');
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.neonCyan,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                L10n.of(context, 'subscription_upgrade_now'),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              L10n.of(context, 'maybe_later'),
              style: TextStyle(color: Colors.grey[400]),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
