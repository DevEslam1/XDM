import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/domain/subscription/subscription_plan.dart';
import '../../../core/services/subscription/subscription_service.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';

/// Bottom sheet shown when a free user attempts a premium-only action.
///
/// Displays the upgrade CTA with plan options and pricing.
class PaywallBottomSheet extends StatefulWidget {
  final SubscriptionService subscriptionService;
  final String? featureName;
  final VoidCallback? onDismiss;

  const PaywallBottomSheet({
    super.key,
    required this.subscriptionService,
    this.featureName,
    this.onDismiss,
  });

  static Future<void> show(
    BuildContext context, {
    String? featureName,
    VoidCallback? onDismiss,
  }) {
    return showDmxModalBottomSheet<void>(
      context: context,
      builder: (_) => PaywallBottomSheet(
        subscriptionService: context.read<SubscriptionService>(),
        featureName: featureName,
        onDismiss: onDismiss,
      ),
    );
  }

  @override
  State<PaywallBottomSheet> createState() => _PaywallBottomSheetState();
}

class _PaywallBottomSheetState extends State<PaywallBottomSheet> {
  SubscriptionPlan _selectedPlan = SubscriptionPlan.annual;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan;
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textSecondary = AppTheme.textSecondaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);

    final highlights = isRtl
        ? const [
            (Icons.bolt_rounded, 'تنزيل متعدد المسارات بأقصى سرعة'),
            (Icons.block_rounded, 'تجربة نظيفة بدون إعلانات'),
            (Icons.hub_rounded, 'أدوات التورنت والوسائط المتقدمة'),
          ]
        : const [
            (Icons.bolt_rounded, 'Max-speed multi-segment acceleration'),
            (Icons.block_rounded, 'Clean, ad-free downloading experience'),
            (Icons.hub_rounded, 'Advanced torrent, playlist & cloud tools'),
          ];

    return DmxSheetContainer(
      scrollable: true,
      showDragHandle: true,
      showHeaderDivider: false,
      isDark: isDark,
      accentColor: accent,
      padding: const EdgeInsets.fromLTRB(
        DmxTokens.sheetHorizontalPadding,
        4,
        DmxTokens.sheetHorizontalPadding,
        16,
      ),
      footer: _buildFooter(context, isDark, accent, textMuted),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top dismiss button row + centered hero emblem
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      accent.withValues(alpha: isDark ? 0.22 : 0.16),
                      accent.withValues(alpha: isDark ? 0.06 : 0.04),
                    ],
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: accent.withValues(alpha: isDark ? 0.35 : 0.28),
                    width: 1,
                  ),
                ),
                child: Icon(
                  Icons.diamond_rounded,
                  color: accent,
                  size: 32,
                ),
              ),
              PositionedDirectional(
                top: 0,
                end: 0,
                child: IconButton(
                  onPressed: () {
                    widget.onDismiss?.call();
                    Navigator.of(context).maybePop();
                  },
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: Icon(Icons.close_rounded, size: 20, color: textMuted),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(38, 38),
                    backgroundColor: isDark
                        ? AppTheme.surfaceRaised.withValues(alpha: 0.7)
                        : AppTheme.lightBgSunken.withValues(alpha: 0.9),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Title
          Text(
            widget.featureName != null
                ? L10n.of(context, 'subscription_unlock_feature')
                : L10n.of(context, 'subscription_go_premium'),
            style: TextStyle(
              fontFamily: AppTheme.fontDisplay,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              color: textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),

          if (widget.featureName != null && widget.featureName!.isNotEmpty) ...[
            Center(
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: isDark ? 0.14 : 0.10),
                  borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
                  border: Border.all(
                    color: accent.withValues(alpha: 0.3),
                    width: 0.8,
                  ),
                ),
                child: Text(
                  widget.featureName!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
              ),
            ),
          ],

          Text(
            L10n.of(context, 'subscription_paywall_subtitle'),
            style: TextStyle(
              fontFamily: AppTheme.fontBody,
              fontSize: 13,
              height: 1.4,
              color: textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),

          // Value highlights
          DmxSheetSection(
            isDark: isDark,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              children: [
                for (var i = 0; i < highlights.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(highlights[i].$1, size: 16, color: accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          highlights[i].$2,
                          style: TextStyle(
                            fontFamily: AppTheme.fontBody,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Plan selection
          ...SubscriptionPlan.all.map(
            (plan) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildPlanOption(context, plan, isDark, accent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(
    BuildContext context,
    bool isDark,
    Color accent,
    Color textMuted,
  ) {
    final dividerColor = AppTheme.hairlineBorder(isDark);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 1, thickness: 0.8, color: dividerColor),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                onPressed: () => _subscribe(context),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 50),
                  backgroundColor: accent,
                  foregroundColor: AppTheme.inkOn(accent),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                  ),
                ),
                child: Text(
                  L10n.of(context, 'subscription_subscribe_now'),
                  style: const TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                L10n.of(context, 'subscription_terms'),
                style: TextStyle(
                  fontFamily: AppTheme.fontBody,
                  fontSize: 11,
                  height: 1.35,
                  color: textMuted,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlanOption(
    BuildContext context,
    SubscriptionPlan plan,
    bool isDark,
    Color accent,
  ) {
    final isSelected = _selectedPlan.id == plan.id;
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textSecondary = AppTheme.textSecondaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);
    final amber = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    final unselectedBorder = AppTheme.hairlineBorder(isDark);

    return GestureDetector(
      onTap: () => setState(() => _selectedPlan = plan),
      child: AnimatedContainer(
        duration: AppTheme.motionFast,
        curve: AppTheme.motionCurve,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected
              ? accent.withValues(alpha: isDark ? 0.12 : 0.08)
              : AppTheme.surfaceColor(isDark, elevated: false),
          borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
          border: Border.all(
            color: isSelected ? accent : unselectedBorder,
            width: isSelected ? 1.8 : 0.8,
          ),
        ),
        child: Row(
          children: [
            // Radio indicator
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? accent : textMuted,
                  width: 2,
                ),
                color: isSelected ? accent : Colors.transparent,
              ),
              child: isSelected
                  ? Center(
                      child: Icon(
                        Icons.check_rounded,
                        size: 13,
                        color: AppTheme.inkOn(accent),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),

            // Plan info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          plan.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: AppTheme.fontDisplay,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: textPrimary,
                          ),
                        ),
                      ),
                      if (plan.isPopular) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color:
                                amber.withValues(alpha: isDark ? 0.18 : 0.14),
                            borderRadius:
                                BorderRadius.circular(DmxTokens.radiusSm),
                            border: Border.all(
                              color: amber.withValues(alpha: 0.35),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            'POPULAR',
                            style: TextStyle(
                              fontFamily: AppTheme.fontDisplay,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: amber,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    plan.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppTheme.fontBody,
                      fontSize: 12,
                      color: textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),

            // Price
            Text(
              '${plan.price}${plan.period}',
              style: AppTheme.dataStyle(
                isDark: isDark,
                size: 15,
                color: isSelected ? accent : textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _subscribe(BuildContext context) {
    Navigator.of(context).pop();
    Navigator.of(context).pushNamed('/subscription');
  }
}
