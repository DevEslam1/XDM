import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/logging_service.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/ad_blocker_service.dart';
import '../services/adblock_filter_updater.dart';

/// Privacy & adblock dashboard bottom sheet displaying ad/popup blocking
/// statistics, connection security status, and site-specific shield controls.
class BrowserShieldSheet extends StatefulWidget {
  final String currentUrl;
  final int blockedAdsCount;
  final int blockedPopupsCount;
  final VoidCallback? onReloadTab;
  final VoidCallback? onStartElementPicker;

  const BrowserShieldSheet({
    super.key,
    required this.currentUrl,
    this.blockedAdsCount = 0,
    this.blockedPopupsCount = 0,
    this.onReloadTab,
    this.onStartElementPicker,
  });

  static Future<void> show({
    required BuildContext context,
    required String currentUrl,
    int blockedAdsCount = 0,
    int blockedPopupsCount = 0,
    VoidCallback? onReloadTab,
    VoidCallback? onStartElementPicker,
  }) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    HapticHelper.triggerHaptic(settings);

    return showDmxModalBottomSheet<void>(
      context: context,
      builder: (context) => BrowserShieldSheet(
        currentUrl: currentUrl,
        blockedAdsCount: blockedAdsCount,
        blockedPopupsCount: blockedPopupsCount,
        onReloadTab: onReloadTab,
        onStartElementPicker: onStartElementPicker,
      ),
    );
  }

  @override
  State<BrowserShieldSheet> createState() => _BrowserShieldSheetState();
}

class _BrowserShieldSheetState extends State<BrowserShieldSheet>
    with HapticHelper {
  final AdBlockerService _adBlocker = AdBlockerService.instance;
  late bool _isAllowlisted;

  @override
  void initState() {
    super.initState();
    _isAllowlisted = _adBlocker.isAllowListed(widget.currentUrl);
  }

  String get _domain {
    if (widget.currentUrl.isEmpty) return '';
    try {
      final uri = Uri.parse(widget.currentUrl);
      return uri.host;
    } catch (e, st) {
      LoggingService.logger('BrowserShieldSheet')
          .warning('Operation failed with fallback', e, st);
      return '';
    }
  }

  bool get _isHttps => widget.currentUrl.toLowerCase().startsWith('https://');

  void _toggleAllowlist(SettingsProvider settings, bool allowlisted) {
    HapticHelper.triggerHaptic(settings);
    setState(() => _isAllowlisted = allowlisted);
    final filterUpdater = AdBlockFilterUpdater.instance;
    if (allowlisted) {
      filterUpdater.addAllowListDomain(_domain);
    } else {
      filterUpdater.removeAllowListDomain(_domain);
    }
    widget.onReloadTab?.call();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isAmoled = settings.isAmoledMode;
    final isRtl = L10n.isRtl(context);

    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final green = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final amber = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    final shieldColor = _isAllowlisted ? amber : green;
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textSecondary = AppTheme.textSecondaryOf(isDark);
    final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);

    final hostTitle = _domain.isNotEmpty
        ? _domain
        : (widget.currentUrl.isEmpty
            ? (isRtl ? 'صفحة محلية' : 'Local Page')
            : widget.currentUrl);

    return Directionality(
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: DmxSheetContainer(
        scrollable: true,
        isDark: isDark,
        isAmoled: isAmoled,
        accentColor: shieldColor,
        header: DmxSheetHeader(
          isDark: isDark,
          accentColor: shieldColor,
          icon: _isAllowlisted ? Icons.shield_outlined : Icons.shield_rounded,
          title: hostTitle,
          subtitle: _isHttps
              ? (isRtl
                  ? 'اتصال آمن ومشفّر (HTTPS)'
                  : 'Connection is secure (HTTPS)')
              : (isRtl ? 'غير مشفّر بـ HTTPS' : 'Not encrypted with HTTPS'),
          trailing: _StatusPill(
            label: _isAllowlisted
                ? (isRtl ? 'مستثنى' : 'Whitelisted')
                : (isRtl ? 'محمي' : 'Protected'),
            icon: _isHttps ? Icons.lock_rounded : Icons.warning_amber_rounded,
            color: shieldColor,
            isDark: isDark,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Prominent shield toggle card (guarded by _domain.isNotEmpty)
            if (_domain.isNotEmpty) ...[
              DmxSheetSection(
                isDark: isDark,
                isAmoled: isAmoled,
                elevated: true,
                accentColor: shieldColor,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: shieldColor.withValues(
                          alpha: isDark ? 0.16 : 0.12,
                        ),
                        borderRadius:
                            BorderRadius.circular(DmxTokens.badgeRadius),
                        border: Border.all(
                          color: shieldColor.withValues(alpha: 0.30),
                          width: DmxTokens.borderThin,
                        ),
                      ),
                      child: Icon(
                        _isAllowlisted
                            ? Icons.gpp_maybe_outlined
                            : Icons.verified_user_rounded,
                        color: shieldColor,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isRtl ? 'حماية الدرع لهذا الموقع' : 'Site Shield',
                            style: TextStyle(
                              fontFamily: AppTheme.fontDisplay,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _isAllowlisted
                                ? (isRtl
                                    ? 'تم إيقاف الحجب لهذا الموقع'
                                    : 'Ad blocking disabled for this site')
                                : (isRtl
                                    ? 'الحجب نشط لهذا الموقع'
                                    : 'Ad blocking active on this site'),
                            style: TextStyle(
                              fontFamily: AppTheme.fontBody,
                              fontSize: DmxTokens.textSm,
                              color: textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Switch.adaptive(
                      value: !_isAllowlisted,
                      activeTrackColor: green.withValues(alpha: 0.45),
                      activeThumbColor: green,
                      onChanged: (enabled) =>
                          _toggleAllowlist(settings, !enabled),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: DmxTokens.sheetSectionGap),
            ],

            // Blocked count stats cards
            Row(
              children: [
                Expanded(
                  child: _ShieldStatCard(
                    icon: Icons.block_rounded,
                    label: isRtl ? 'إعلانات محجوبة' : 'Ads Blocked',
                    count: widget.blockedAdsCount,
                    color: accent,
                    isDark: isDark,
                    isAmoled: isAmoled,
                  ),
                ),
                const SizedBox(width: DmxTokens.cardGap),
                Expanded(
                  child: _ShieldStatCard(
                    icon: Icons.tab_unselected_rounded,
                    label: isRtl ? 'نوافذ منبثقة' : 'Popups Blocked',
                    count: widget.blockedPopupsCount,
                    color: green,
                    isDark: isDark,
                    isAmoled: isAmoled,
                  ),
                ),
              ],
            ),
            const SizedBox(height: DmxTokens.sheetSectionGap),

            // Site-specific controls
            DmxSheetSection(
              title: isRtl ? 'أدوات الصفحة' : 'SITE CONTROLS',
              isDark: isDark,
              isAmoled: isAmoled,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ShieldActionTile(
                    icon: Icons.touch_app_rounded,
                    label:
                        isRtl ? 'اختر عنصراً لحجبه' : 'Pick Element to Block',
                    subtitle: isRtl
                        ? 'إخفاء عنصر مزعج من الصفحة الحالية'
                        : 'Hide an unwanted element on this page',
                    accent: accent,
                    isDark: isDark,
                    isRtl: isRtl,
                    onTap: () {
                      HapticHelper.triggerHaptic(settings);
                      Navigator.pop(context);
                      widget.onStartElementPicker?.call();
                    },
                  ),
                  if (widget.onReloadTab != null) ...[
                    Divider(
                      height: 1,
                      thickness: DmxTokens.borderThin,
                      color: borderClr,
                    ),
                    _ShieldActionTile(
                      icon: Icons.refresh_rounded,
                      label: isRtl ? 'إعادة تحميل الصفحة' : 'Reload Page',
                      subtitle: isRtl
                          ? 'تطبيق إعدادات الحماية فوراً'
                          : 'Re-apply shield rules on this tab',
                      accent: green,
                      isDark: isDark,
                      isRtl: isRtl,
                      onTap: () {
                        HapticHelper.triggerHaptic(settings);
                        Navigator.pop(context);
                        widget.onReloadTab?.call();
                      },
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool isDark;

  const _StatusPill({
    required this.label,
    required this.icon,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
        border: Border.all(
          color: color.withValues(alpha: isDark ? 0.30 : 0.24),
          width: DmxTokens.borderThin,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontFamily: AppTheme.fontDisplay,
              fontSize: DmxTokens.textXs,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _ShieldStatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final Color color;
  final bool isDark;
  final bool isAmoled;

  const _ShieldStatCard({
    required this.icon,
    required this.label,
    required this.count,
    required this.color,
    required this.isDark,
    required this.isAmoled,
  });

  @override
  Widget build(BuildContext context) {
    final textSecondary = AppTheme.textSecondaryOf(isDark);
    return Container(
      padding: const EdgeInsets.all(DmxTokens.cardPadding),
      decoration: BoxDecoration(
        color:
            AppTheme.surfaceColor(isDark, isAmoled: isAmoled, elevated: true),
        borderRadius: BorderRadius.circular(DmxTokens.radiusLg),
        border: Border.all(
          color: AppTheme.hairlineBorder(isDark, isAmoled: isAmoled),
          width: DmxTokens.borderThin,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: isDark ? 0.14 : 0.10),
                  borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
                ),
                child: Icon(icon, size: 15, color: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTheme.fontBody,
                    fontSize: DmxTokens.textSm,
                    fontWeight: FontWeight.w500,
                    color: textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '$count',
            style: AppTheme.dataStyle(
              isDark: isDark,
              size: 24,
              weight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _ShieldActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color accent;
  final bool isDark;
  final bool isRtl;
  final VoidCallback onTap;

  const _ShieldActionTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.accent,
    required this.isDark,
    required this.isRtl,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textSecondary = AppTheme.textSecondaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: isDark ? 0.14 : 0.10),
                  borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
                ),
                child: Icon(icon, size: 18, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppTheme.fontDisplay,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppTheme.fontBody,
                        fontSize: DmxTokens.textXs,
                        color: textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                isRtl
                    ? Icons.chevron_left_rounded
                    : Icons.chevron_right_rounded,
                size: 18,
                color: textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
