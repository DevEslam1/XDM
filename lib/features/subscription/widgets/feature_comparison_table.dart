import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/domain/subscription/entitlement.dart';
import '../../../core/domain/subscription/subscription_tier.dart';
import '../../../core/utils/localization.dart';

/// Side-by-side feature comparison table for Free vs Premium tiers.
class FeatureComparisonTable extends StatelessWidget {
  const FeatureComparisonTable({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const freeTier = SubscriptionTier.free;
    const premiumTier = SubscriptionTier.premium;
    final freeEntitlements = Entitlement.forTier(freeTier);
    final premiumEntitlements = Entitlement.forTier(premiumTier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          L10n.of(context, 'subscription_compare_plans'),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.03)
                : Colors.black.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            children: [
              // Header row
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.black.withValues(alpha: 0.08),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(
                        L10n.of(context, 'subscription_feature'),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[400],
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          L10n.of(context, 'subscription_free'),
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.grey[400],
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          L10n.of(context, 'subscription_premium'),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppTheme.neonCyan,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Feature rows
              for (int i = 0; i < freeEntitlements.length; i++)
                _buildFeatureRow(
                  context,
                  freeEntitlements[i],
                  premiumEntitlements[i],
                  isDark,
                  i < freeEntitlements.length - 1,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFeatureRow(
    BuildContext context,
    Entitlement freeEntitlement,
    Entitlement premiumEntitlement,
    bool isDark,
    bool showBorder,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: showBorder
          ? BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.black.withValues(alpha: 0.05),
                ),
              ),
            )
          : null,
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              freeEntitlement.displayName,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: _buildStatusIcon(freeEntitlement.isEnabled),
            ),
          ),
          Expanded(
            child: Center(
              child: _buildStatusIcon(premiumEntitlement.isEnabled),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIcon(bool enabled) {
    return Icon(
      enabled ? Icons.check_circle_rounded : Icons.cancel_rounded,
      size: 18,
      color: enabled ? AppTheme.neonGreen : Colors.grey.withValues(alpha: 0.3),
    );
  }
}
