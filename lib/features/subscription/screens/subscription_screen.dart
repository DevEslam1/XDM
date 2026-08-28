import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/domain/subscription/subscription_plan.dart';
import '../../../core/services/subscription/purchase_service.dart';
import '../../../core/services/subscription/subscription_service.dart';
import '../../../core/utils/localization.dart';
import '../provider/subscription_provider.dart';
import '../widgets/feature_comparison_table.dart';
import '../widgets/plan_card.dart';
import '../widgets/subscription_status_banner.dart';

/// Main subscription management screen.
class SubscriptionScreen extends StatelessWidget {
  const SubscriptionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => SubscriptionProvider(
        subscriptionService: context.read<SubscriptionService>(),
        purchaseService: context.read<PurchaseService>(),
      ),
      child: const _SubscriptionView(),
    );
  }
}

class _SubscriptionView extends StatelessWidget {
  const _SubscriptionView();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SubscriptionProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppTheme.background : AppTheme.lightBackground,
      appBar: AppBar(
        title: Text(L10n.of(context, 'subscription_title')),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (provider.isPremium)
            TextButton(
              onPressed: () => _showManageSubscription(context),
              child: Text(
                L10n.of(context, 'subscription_manage'),
                style: const TextStyle(color: AppTheme.neonCyan),
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status banner
            SubscriptionStatusBanner(provider: provider),
            const SizedBox(height: 24),

            // Plan cards
            if (provider.isFree) ...[
              Text(
                L10n.of(context, 'subscription_choose_plan'),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 16),
              ...SubscriptionPlan.all.map((plan) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: PlanCard(
                      plan: plan,
                      isSelected: provider.selectedPlan?.id == plan.id,
                      onSelect: () => provider.selectPlan(plan),
                    ),
                  )),
              const SizedBox(height: 16),

              // Purchase button
              if (provider.selectedPlan != null)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: provider.isPurchasing
                        ? null
                        : () => _purchase(context, provider),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.neonCyan,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: provider.isPurchasing
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : Text(
                            L10n.of(context, 'subscription_subscribe'),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                  ),
                ),

              // Error display
              if (provider.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.neonRed.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppTheme.neonRed.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline,
                            color: AppTheme.neonRed, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            provider.error!,
                            style: const TextStyle(
                                color: AppTheme.neonRed, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              const SizedBox(height: 20),

              // Restore purchases
              Center(
                child: TextButton(
                  onPressed: () => _restore(context, provider),
                  child: Text(
                    L10n.of(context, 'subscription_restore'),
                    style: TextStyle(color: Colors.grey[400]),
                  ),
                ),
              ),
            ],

            // Feature comparison
            const SizedBox(height: 24),
            const FeatureComparisonTable(),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Future<void> _purchase(
      BuildContext context, SubscriptionProvider provider) async {
    final success = await provider.purchaseSelectedPlan();
    if (success && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context, 'subscription_welcome_premium')),
          backgroundColor: AppTheme.neonGreen,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  Future<void> _restore(
      BuildContext context, SubscriptionProvider provider) async {
    final success = await provider.restorePurchases();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? L10n.of(context, 'subscription_restore_success')
              : L10n.of(context, 'subscription_restore_failed')),
          backgroundColor: success ? AppTheme.neonGreen : AppTheme.neonRed,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  void _showManageSubscription(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (_) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              L10n.of(context, 'subscription_manage'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Text(L10n.of(context, 'subscription_manage_description')),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
