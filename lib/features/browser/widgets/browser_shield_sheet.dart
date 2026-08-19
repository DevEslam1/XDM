import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/logging_service.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/ad_blocker_service.dart';
import '../services/adblock_filter_updater.dart';

/// Modern Shield bottom sheet displaying ad & tracking statistics,
/// security status, and quick whitelist toggle for the active site.
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

    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
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

  bool get _isHttps {
    return widget.currentUrl.toLowerCase().startsWith('https://');
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isAmoled = settings.isAmoledMode;
    final isRtl = L10n.isRtl(context);

    final bgClr = isAmoled
        ? Colors.black
        : (isDark ? AppTheme.surface : AppTheme.lightSurface);
    final cardBg = isAmoled
        ? const Color(0xFF0A0A0A)
        : (isDark ? AppTheme.cardBg : AppTheme.lightCardBg);
    final textPrimary = isDark ? Colors.white : Colors.black87;
    final textMuted = isDark ? Colors.white54 : Colors.black54;
    final borderClr =
        isDark ? AppTheme.border.withValues(alpha: 0.5) : AppTheme.lightBorder;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final green = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      decoration: BoxDecoration(
        color: bgClr,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
          top: BorderSide(
            color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
            width: 1,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.2)
                    : Colors.black.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Header with domain & security status
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (_isHttps ? green : AppTheme.neonAmber)
                      .withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _isHttps ? Icons.lock_rounded : Icons.warning_amber_rounded,
                  color: _isHttps ? green : AppTheme.neonAmber,
                  size: 20,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _domain.isNotEmpty
                          ? _domain
                          : (widget.currentUrl.isEmpty
                              ? 'Local Page'
                              : widget.currentUrl),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _isHttps
                          ? (isRtl
                              ? 'اتصال آمن ومشفّر (HTTPS)'
                              : 'Connection is secure (HTTPS)')
                          : (isRtl
                              ? 'غير مشفّر بـ HTTPS'
                              : 'Not encrypted with HTTPS'),
                      style: TextStyle(
                        fontSize: 11,
                        color: _isHttps ? green : AppTheme.neonAmber,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _isAllowlisted
                      ? AppTheme.neonAmber.withValues(alpha: 0.12)
                      : green.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _isAllowlisted
                        ? AppTheme.neonAmber.withValues(alpha: 0.3)
                        : green.withValues(alpha: 0.3),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isAllowlisted
                          ? Icons.shield_outlined
                          : Icons.shield_rounded,
                      size: 13,
                      color: _isAllowlisted ? AppTheme.neonAmber : green,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _isAllowlisted
                          ? (isRtl ? 'مستثنى' : 'Whitelisted')
                          : (isRtl ? 'محمي' : 'Protected'),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: _isAllowlisted ? AppTheme.neonAmber : green,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Protection statistics card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderClr, width: 0.5),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.block_rounded, size: 16, color: accent),
                          const SizedBox(width: 6),
                          Text(
                            isRtl ? 'إعلانات محجوبة' : 'Ads Blocked',
                            style: TextStyle(fontSize: 12, color: textMuted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${widget.blockedAdsCount}',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: accent,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 36,
                  width: 1,
                  color: borderClr,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.tab_unselected_rounded,
                              size: 16, color: green),
                          const SizedBox(width: 6),
                          Text(
                            isRtl ? 'نوافذ منبثقة' : 'Popups Blocked',
                            style: TextStyle(fontSize: 12, color: textMuted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${widget.blockedPopupsCount}',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: green,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Whitelist toggle tile (Guarded by _domain.isNotEmpty)
          if (_domain.isNotEmpty) ...[
            Container(
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: borderClr, width: 0.5),
              ),
              child: SwitchListTile(
                activeThumbColor: accent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: Text(
                  isRtl ? 'استثناء هذا الموقع' : 'Whitelist this site',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: textPrimary,
                  ),
                ),
                subtitle: Text(
                  _isAllowlisted
                      ? (isRtl
                          ? 'تم إيقاف الحجب لهذا الموقع'
                          : 'Ad blocking disabled for this site')
                      : (isRtl
                          ? 'الحجب نشط لهذا الموقع'
                          : 'Ad blocking active on this site'),
                  style: TextStyle(fontSize: 11, color: textMuted),
                ),
                value: _isAllowlisted,
                onChanged: (val) async {
                  HapticHelper.triggerHaptic(settings);
                  setState(() => _isAllowlisted = val);
                  final filterUpdater = AdBlockFilterUpdater.instance;
                  if (val) {
                    filterUpdater.addAllowListDomain(_domain);
                  } else {
                    filterUpdater.removeAllowListDomain(_domain);
                  }
                  widget.onReloadTab?.call();
                },
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Block Element Button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                side: BorderSide(color: accent.withValues(alpha: 0.5)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: Icon(Icons.touch_app_rounded, size: 18, color: accent),
              label: Text(
                isRtl ? 'اختر عنصراً لحجبه' : 'Pick Element to Block',
                style: TextStyle(
                  color: accent,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              onPressed: () {
                HapticHelper.triggerHaptic(settings);
                Navigator.pop(context);
                widget.onStartElementPicker?.call();
              },
            ),
          ),
        ],
      ),
    );
  }
}
