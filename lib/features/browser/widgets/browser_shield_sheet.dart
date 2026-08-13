import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/ad_blocker_service.dart';
import '../services/adblock_filter_updater.dart';

/// Quick Site Security & AdBlock Shield bottom sheet.
class BrowserShieldSheet extends StatefulWidget {
  final String currentUrl;
  final int blockedAdsCount;
  final int blockedPopupsCount;
  final VoidCallback? onStartElementPicker;
  final VoidCallback? onReloadTab;

  const BrowserShieldSheet({
    super.key,
    required this.currentUrl,
    required this.blockedAdsCount,
    required this.blockedPopupsCount,
    this.onStartElementPicker,
    this.onReloadTab,
  });

  static Future<void> show({
    required BuildContext context,
    required String currentUrl,
    required int blockedAdsCount,
    required int blockedPopupsCount,
    VoidCallback? onStartElementPicker,
    VoidCallback? onReloadTab,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => BrowserShieldSheet(
        currentUrl: currentUrl,
        blockedAdsCount: blockedAdsCount,
        blockedPopupsCount: blockedPopupsCount,
        onStartElementPicker: onStartElementPicker,
        onReloadTab: onReloadTab,
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
    if (widget.currentUrl.isEmpty) return 'Local Page';
    try {
      final uri = Uri.parse(widget.currentUrl);
      return uri.host.isNotEmpty ? uri.host : widget.currentUrl;
    } catch (_) {
      return widget.currentUrl;
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
    final cardBg = isDark
        ? (isAmoled ? AppTheme.amoledCardBg : Colors.white.withValues(alpha: 0.05))
        : Colors.black.withValues(alpha: 0.03);
    final borderClr = isDark
        ? (isAmoled ? AppTheme.amoledBorder : AppTheme.glassBorder)
        : AppTheme.lightGlassBorder;
    final textPrimary =
        isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final textMuted = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final green = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;

    return Container(
      decoration: BoxDecoration(
        color: bgClr,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: borderClr, width: 0.8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 20,
            spreadRadius: 4,
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.black12,
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
                      _domain,
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
            ],
          ),
          const SizedBox(height: 20),

          // Stats tile (Blocked Ads & Popups)
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
                          Icon(Icons.shield_rounded, size: 16, color: accent),
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
                  width: 1,
                  height: 36,
                  color: isDark ? Colors.white10 : Colors.black12,
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

          // Whitelist toggle tile
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
                lightPulse(settings);
                setState(() => _isAllowlisted = val);
                final filterUpdater = AdBlockFilterUpdater();
                if (val) {
                  filterUpdater.allowListedDomains.add(_domain.toLowerCase());
                } else {
                  filterUpdater.allowListedDomains.remove(_domain.toLowerCase());
                }
                widget.onReloadTab?.call();
              },
            ),
          ),
          const SizedBox(height: 12),

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
                lightPulse(settings);
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
