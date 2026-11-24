import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/share_url_handler.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';
import '../../../shared/widgets/themed_snackbar.dart';

class BrowserExtensionsSheet extends StatefulWidget {
  const BrowserExtensionsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showDmxModalBottomSheet<void>(
      context: context,
      builder: (_) => const BrowserExtensionsSheet(),
    );
  }

  @override
  State<BrowserExtensionsSheet> createState() => _BrowserExtensionsSheetState();
}

class _BrowserExtensionsSheetState extends State<BrowserExtensionsSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_handleTabChange);
  }

  void _handleTabChange() {
    if (_tabController.index != _selectedIndex && mounted) {
      setState(() => _selectedIndex = _tabController.index);
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _openSafariSettings(BuildContext context) async {
    final Uri url = Uri.parse('App-Prefs:Safari');
    final Uri fallbackUrl = Uri.parse('app-settings:');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url);
      } else if (await canLaunchUrl(fallbackUrl)) {
        await launchUrl(fallbackUrl);
      } else if (context.mounted) {
        _showInfoSnackbar(
          context,
          'Open Settings -> Safari -> Extensions on your iOS device.',
        );
      }
    } catch (_) {
      if (context.mounted) {
        _showInfoSnackbar(
          context,
          'Open Settings -> Safari -> Extensions on your iOS device.',
        );
      }
    }
  }

  void _showInfoSnackbar(BuildContext context, String message) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    ThemedSnackbar.show(
      context,
      message: message,
      color: isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan,
      icon: Icons.info_outline_rounded,
      isDarkMode: isDark,
    );
  }

  void _testDeepLink(BuildContext context) {
    const testUrl =
        'dmx://add?url=https%3A%2F%2Fsample-videos.com%2Fvideo321%2Fmp4%2F720%2Fbig_buck_bunny_720p_1mb.mp4&name=Sample_Video.mp4&source=browser_ext';
    ShareUrlHandler.handleDeepLink(
      Uri.parse(testUrl),
      onUrl: (url) {
        ShareUrlHandler.handle(
          context,
          url,
          isShareLaunch: false,
          prefilledName: 'Sample_Video.mp4',
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan;
    final panelBg = AppTheme.panelBg(isDark);
    final hairline = AppTheme.hairlineBorder(isDark);

    return DmxSheetContainer(
      scrollable: false,
      maxHeightFraction: 0.88,
      isDark: isDark,
      accentColor: accent,
      padding: EdgeInsets.zero,
      header: DmxSheetHeader(
        title: isRtl
            ? 'ملحقات المتصفح (Browser Plugins)'
            : 'Browser Plugins & Interceptor',
        subtitle: isRtl
            ? 'إلغاء تنزيلات المتصفح وتحويلها تلقائياً إلى XDM'
            : 'Auto-intercept & redirect downloads directly to XDM',
        icon: Icons.extension_rounded,
        accentColor: accent,
        isDark: isDark,
      ),
      child: Column(
        children: [
          // Segmented platform switcher
          Padding(
            padding: const EdgeInsets.fromLTRB(
              DmxTokens.sheetHorizontalPadding,
              14,
              DmxTokens.sheetHorizontalPadding,
              10,
            ),
            child: Container(
              height: 44,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: panelBg,
                borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                border: Border.all(color: hairline, width: 0.8),
              ),
              child: Row(
                children: [
                  _buildPlatformTab(
                    index: 0,
                    label: 'Firefox (Android)',
                    icon: FontAwesomeIcons.firefox,
                    accent: accent,
                    isDark: isDark,
                  ),
                  _buildPlatformTab(
                    index: 1,
                    label: 'Safari (iOS)',
                    icon: FontAwesomeIcons.safari,
                    accent: accent,
                    isDark: isDark,
                  ),
                ],
              ),
            ),
          ),

          // Tab Content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildFirefoxTab(context, accent, isDark, isRtl),
                _buildSafariTab(context, accent, isDark, isRtl),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformTab({
    required int index,
    required String label,
    required FaIconData icon,
    required Color accent,
    required bool isDark,
  }) {
    final isSelected = _selectedIndex == index;
    final textSecondary = AppTheme.textSecondaryOf(isDark);

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _tabController.animateTo(index);
          setState(() => _selectedIndex = index);
        },
        child: AnimatedContainer(
          duration: AppTheme.motionFast,
          curve: AppTheme.motionCurve,
          decoration: BoxDecoration(
            color: isSelected
                ? accent.withValues(alpha: isDark ? 0.16 : 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: isSelected
                ? Border.all(
                    color: accent.withValues(alpha: 0.35),
                    width: 0.8,
                  )
                : null,
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FaIcon(
                  icon,
                  size: 14,
                  color: isSelected ? accent : textSecondary,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      fontSize: 12,
                      fontWeight:
                          isSelected ? FontWeight.w700 : FontWeight.w500,
                      color: isSelected ? accent : textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFirefoxTab(
    BuildContext context,
    Color accent,
    bool isDark,
    bool isRtl,
  ) {
    final steps = [
      isRtl
          ? 'افتح متصفح Firefox على جهاز Android.'
          : 'Open Firefox on your Android device.',
      isRtl
          ? 'افتح القائمة السريعة -> الملحقات (Add-ons).'
          : 'Open Menu -> Add-ons / Extensions.',
      isRtl
          ? 'قم بتثبيت ملحق "XDM Download Redirect" (الموافق لـ Manifest V2).'
          : 'Load / Install "XDM Download Redirect" extension (xdm-firefox folder).',
      isRtl
          ? 'بمجرد التفعيل، سيتم إرسال أي رابط ملف أو Magnet تلقائياً إلى XDM.'
          : 'Once enabled, all file downloads, .zip, .mp4, and magnet links immediately trigger XDM!',
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        DmxTokens.sheetHorizontalPadding,
        6,
        DmxTokens.sheetHorizontalPadding,
        20,
      ),
      children: [
        _buildInfoCard(
          isDark: isDark,
          accent: accent,
          platformBadge: 'ANDROID',
          statusLabel: isRtl ? 'بروتوكول dmx://' : 'dmx:// Ready',
          title:
              isRtl ? 'ملحق Firefox Android' : 'Firefox (Android) Redirector',
          description: isRtl
              ? 'يقوم الملحق بمراقبة كل تنزيل يتم البدء فيه داخل متصفح Firefox، وإلغائه فورياً داخل المتصفح، وتحويل رابط التنزيل إلى تطبيق XDM لتنزيله بأقصى سرعة.'
              : 'Every download initiated in Firefox is cancelled in the browser and passed to XDM via dmx:// deep link.',
          icon: FontAwesomeIcons.firefox,
        ),
        const SizedBox(height: 16),
        DmxSheetSection(
          title:
              isRtl ? 'خطوات التثبيت والتفعيل' : 'Installation & Setup Steps',
          isDark: isDark,
          child: Column(
            children: [
              for (var i = 0; i < steps.length; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                _buildStepItem(isDark, accent, '${i + 1}', steps[i]),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _buildActionButtons(
          isDark: isDark,
          accent: accent,
          primaryLabel: isRtl ? 'نسخ بروتوكول dmx://' : 'Copy dmx:// Protocol',
          primaryIcon: Icons.copy_rounded,
          onPrimary: () {
            Clipboard.setData(const ClipboardData(text: 'dmx://add?url='));
            _showInfoSnackbar(
              context,
              isRtl
                  ? 'تم نسخ البروتوكول dmx://'
                  : 'Copied dmx:// scheme to clipboard',
            );
          },
          secondaryLabel: isRtl ? 'اختبار التحويل' : 'Test Interception',
          onSecondary: () => _testDeepLink(context),
        ),
      ],
    );
  }

  Widget _buildSafariTab(
    BuildContext context,
    Color accent,
    bool isDark,
    bool isRtl,
  ) {
    final steps = [
      isRtl
          ? 'افتح تطبيق الإعدادات (Settings) في iOS.'
          : 'Open iOS Settings app.',
      isRtl
          ? 'انتقل إلى Safari -> الملحقات (Extensions).'
          : 'Navigate to Safari -> Extensions.',
      isRtl
          ? 'قم بتفعيل ملحق "XDM Download Redirect".'
          : 'Turn ON "XDM Download Redirect".',
      isRtl
          ? 'اختر "السماح لجميع المواقع" (Allow on All Websites) لمنح صلاحية التحويل.'
          : 'Set permissions to "Allow on All Websites" for seamless background interception.',
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        DmxTokens.sheetHorizontalPadding,
        6,
        DmxTokens.sheetHorizontalPadding,
        20,
      ),
      children: [
        _buildInfoCard(
          isDark: isDark,
          accent: accent,
          platformBadge: 'IOS',
          statusLabel: isRtl ? 'ملحق الويب' : 'Web Extension',
          title: isRtl
              ? 'ملحق Safari Web Extension (iOS)'
              : 'Safari (iOS) Web Extension',
          description: isRtl
              ? 'ملحق متكامل مع نظام iOS يمنع تنزيل الملفات بطيئة السرعة داخل Safari ويفتح تطبيق XDM فورياً لبدء التنزيل المتعدد.'
              : 'Built into iOS via Safari Web Extensions. It stops Safari background downloads and forwards the media URL directly to XDM.',
          icon: FontAwesomeIcons.safari,
        ),
        const SizedBox(height: 16),
        DmxSheetSection(
          title: isRtl ? 'خطوات التفعيل في نظام iOS' : 'iOS Activation Steps',
          isDark: isDark,
          child: Column(
            children: [
              for (var i = 0; i < steps.length; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                _buildStepItem(isDark, accent, '${i + 1}', steps[i]),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _buildActionButtons(
          isDark: isDark,
          accent: accent,
          primaryLabel: isRtl ? 'فتح إعدادات Safari' : 'Open Safari Settings',
          primaryIcon: Icons.settings_outlined,
          onPrimary: () => _openSafariSettings(context),
          secondaryLabel: isRtl ? 'اختبار التحويل' : 'Test Interception',
          onSecondary: () => _testDeepLink(context),
        ),
      ],
    );
  }

  Widget _buildActionButtons({
    required bool isDark,
    required Color accent,
    required String primaryLabel,
    required IconData primaryIcon,
    required VoidCallback onPrimary,
    required String secondaryLabel,
    required VoidCallback onSecondary,
  }) {
    final hairline = AppTheme.hairlineBorder(isDark, strong: true);
    final textPrimary = AppTheme.textPrimaryOf(isDark);

    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: onPrimary,
            icon: Icon(primaryIcon, size: 17),
            label: Text(
              primaryLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: AppTheme.fontDisplay,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 48),
              backgroundColor: accent,
              foregroundColor: AppTheme.inkOn(accent),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onSecondary,
            icon: Icon(Icons.flash_on_rounded, size: 17, color: accent),
            label: Text(
              secondaryLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AppTheme.fontDisplay,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: textPrimary,
              ),
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              side: BorderSide(color: hairline, width: 1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoCard({
    required bool isDark,
    required Color accent,
    required String platformBadge,
    required String statusLabel,
    required String title,
    required String description,
    required FaIconData icon,
  }) {
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textSecondary = AppTheme.textSecondaryOf(isDark);
    final green = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: isDark ? 0.08 : 0.05),
        borderRadius: BorderRadius.circular(DmxTokens.radiusLg),
        border: Border.all(
          color: accent.withValues(alpha: isDark ? 0.25 : 0.22),
          width: 0.8,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: isDark ? 0.14 : 0.10),
              borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
              border: Border.all(
                color: accent.withValues(alpha: 0.28),
                width: 0.8,
              ),
            ),
            child: FaIcon(icon, color: accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: isDark ? 0.16 : 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        platformBadge,
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: accent,
                        ),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: green,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          statusLabel,
                          style: TextStyle(
                            fontFamily: AppTheme.fontDisplay,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: green,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontFamily: AppTheme.fontBody,
                    fontSize: 12,
                    height: 1.45,
                    color: textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepItem(
    bool isDark,
    Color accent,
    String number,
    String text,
  ) {
    final textSecondary = AppTheme.textSecondaryOf(isDark);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: isDark ? 0.14 : 0.10),
            shape: BoxShape.circle,
            border: Border.all(
              color: accent.withValues(alpha: 0.35),
              width: 0.8,
            ),
          ),
          child: Text(
            number,
            style: TextStyle(
              fontFamily: AppTheme.fontDisplay,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              text,
              style: TextStyle(
                fontFamily: AppTheme.fontBody,
                fontSize: 12.5,
                height: 1.4,
                color: textSecondary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
