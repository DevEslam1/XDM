import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/services/share_url_handler.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';

class BrowserExtensionsSheet extends StatefulWidget {
  const BrowserExtensionsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const BrowserExtensionsSheet(),
    );
  }

  @override
  State<BrowserExtensionsSheet> createState() => _BrowserExtensionsSheetState();
}

class _BrowserExtensionsSheetState extends State<BrowserExtensionsSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
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
      } else {
        if (context.mounted) {
          _showCopiedSnackbar(
            context,
            'Open Settings -> Safari -> Extensions on your iOS device.',
          );
        }
      }
    } catch (_) {
      if (context.mounted) {
        _showCopiedSnackbar(
          context,
          'Open Settings -> Safari -> Extensions on your iOS device.',
        );
      }
    }
  }

  void _showCopiedSnackbar(BuildContext context, String message) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    ThemedSnackbar.show(
      context,
      message: message,
      color: isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan,
      icon: Icons.info_outline,
      isDarkMode: isDark,
    );
  }

  void _testDeepLink(BuildContext context) {
    const testUrl =
        'dmx://add?url=https%3A%2F%2Fsample-videos.com%2Fvideo321%2Fmp4%2F720%2Fbig_buck_bunny_720p_1mb.mp4&name=Sample_Video.mp4&source=browser_ext';
    ShareUrlHandler.handleDeepLink(
      Uri.parse(testUrl),
      onUrl: (url) {
        ShareUrlHandler.handle(context, url,
            isShareLaunch: false, prefilledName: 'Sample_Video.mp4');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan;
    final surfaceColor = isDark
        ? AppTheme.surface.withValues(alpha: 0.85)
        : AppTheme.lightSurface.withValues(alpha: 0.95);

    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: Container(
            color: surfaceColor,
            child: DmxBackdropFilter(
              sigmaX: 16,
              sigmaY: 16,
              child: Column(
                children: [
                  // Handle indicator
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 6),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark
                          ? AppTheme.borderSubtle
                          : AppTheme.lightBorderSubtle,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),

                  // Header
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Icon(Icons.extension_rounded,
                              color: accent, size: 24),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isRtl
                                    ? 'ملحقات المتصفح (Browser Plugins)'
                                    : 'Browser Plugins & Interceptor',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: isDark
                                      ? AppTheme.textPrimary
                                      : AppTheme.lightTextPrimary,
                                  fontFamily: 'Space Grotesk',
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                isRtl
                                    ? 'إلغاء تنزيلات المتصفح وتحويلها تلقائياً إلى XDM'
                                    : 'Auto-intercept & redirect downloads directly to XDM',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isDark
                                      ? AppTheme.textMuted
                                      : AppTheme.lightTextMuted,
                                  fontFamily: 'Inter',
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),

                  // Tab Bar
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 20),
                    decoration: BoxDecoration(
                      color: isDark ? AppTheme.surface : AppTheme.lightSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark
                            ? AppTheme.borderSubtle
                            : AppTheme.lightBorderSubtle,
                      ),
                    ),
                    child: TabBar(
                      controller: _tabController,
                      indicatorColor: accent,
                      labelColor: accent,
                      unselectedLabelColor:
                          isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                      tabs: const [
                        Tab(
                          icon: FaIcon(FontAwesomeIcons.firefox, size: 16),
                          text: 'Firefox (Android)',
                        ),
                        Tab(
                          icon: FaIcon(FontAwesomeIcons.safari, size: 16),
                          text: 'Safari (iOS)',
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Tab Content
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _buildFirefoxTab(
                            context, scrollController, accent, isDark, isRtl),
                        _buildSafariTab(
                            context, scrollController, accent, isDark, isRtl),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFirefoxTab(
    BuildContext context,
    ScrollController scrollController,
    Color accent,
    bool isDark,
    bool isRtl,
  ) {
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      children: [
        _buildInfoCard(
          isDark: isDark,
          accent: accent,
          title:
              isRtl ? 'ملحق Firefox Android' : 'Firefox (Android) Redirector',
          description: isRtl
              ? 'يقوم الملحق بمراقبة كل تنزيل يتم البدء فيه داخل متصفح Firefox، وإلغائه فورياً داخل المتصفح، وتحويل رابط التنزيل إلى تطبيق XDM لتنزيله بأقصى سرعة.'
              : 'Every download initiated in Firefox is cancelled in the browser and passed to XDM via dmx:// deep link.',
          icon: FontAwesomeIcons.firefox,
        ),
        const SizedBox(height: 16),
        _buildStepHeader(isDark,
            isRtl ? 'خطوات التثبيت والتفعيل:' : 'Installation & Setup Steps:'),
        _buildStepItem(
            isDark,
            '1',
            isRtl
                ? 'افتح متصفح Firefox على جهاز Android.'
                : 'Open Firefox on your Android device.'),
        _buildStepItem(
            isDark,
            '2',
            isRtl
                ? 'افتح القائمة السريعة -> الملحقات (Add-ons).'
                : 'Open Menu -> Add-ons / Extensions.'),
        _buildStepItem(
          isDark,
          '3',
          isRtl
              ? 'قم بتثبيت ملحق "XDM Download Redirect" (الموافق لـ Manifest V2).'
              : 'Load / Install "XDM Download Redirect" extension (xdm-firefox folder).',
        ),
        _buildStepItem(
          isDark,
          '4',
          isRtl
              ? 'بمجرد التفعيل، سيتم إرسال أي رابط ملف أو Magnet تلقائياً إلى XDM.'
              : 'Once enabled, all file downloads, .zip, .mp4, and magnet links immediately trigger XDM!',
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: NeonGlowButton(
                text: isRtl ? 'نسخ بروتوكول dmx://' : 'Copy dmx:// Protocol',
                color: accent,
                onPressed: () {
                  Clipboard.setData(
                      const ClipboardData(text: 'dmx://add?url='));
                  _showCopiedSnackbar(
                      context,
                      isRtl
                          ? 'تم نسخ البروتوكول dmx://'
                          : 'Copied dmx:// scheme to clipboard');
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.flash_on_rounded, size: 18),
                label: Text(isRtl ? 'اختبار التحويل' : 'Test Interception'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: accent,
                  side: BorderSide(color: accent),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => _testDeepLink(context),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSafariTab(
    BuildContext context,
    ScrollController scrollController,
    Color accent,
    bool isDark,
    bool isRtl,
  ) {
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      children: [
        _buildInfoCard(
          isDark: isDark,
          accent: accent,
          title: isRtl
              ? 'ملحق Safari Web Extension (iOS)'
              : 'Safari (iOS) Web Extension',
          description: isRtl
              ? 'ملحق متكامل مع نظام iOS يمنع تنزيل الملفات بطيئة السرعة داخل Safari ويفتح تطبيق XDM فورياً لبدء التنزيل المتعدد.'
              : 'Built into iOS via Safari Web Extensions. It stops Safari background downloads and forwards the media URL directly to XDM.',
          icon: FontAwesomeIcons.safari,
        ),
        const SizedBox(height: 16),
        _buildStepHeader(isDark,
            isRtl ? 'خطوات التفعيل في نظام iOS:' : 'iOS Activation Steps:'),
        _buildStepItem(
            isDark,
            '1',
            isRtl
                ? 'افتح تطبيق الإعدادات (Settings) في iOS.'
                : 'Open iOS Settings app.'),
        _buildStepItem(
            isDark,
            '2',
            isRtl
                ? 'انتقل إلى Safari -> الملحقات (Extensions).'
                : 'Navigate to Safari -> Extensions.'),
        _buildStepItem(
            isDark,
            '3',
            isRtl
                ? 'قم بتفعيل ملحق "XDM Download Redirect".'
                : 'Turn ON "XDM Download Redirect".'),
        _buildStepItem(
          isDark,
          '4',
          isRtl
              ? 'اختر "السماح لجميع المواقع" (Allow on All Websites) لمنح صلاحية التحويل.'
              : 'Set permissions to "Allow on All Websites" for seamless background interception.',
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: NeonGlowButton(
                text: isRtl ? 'فتح إعدادات Safari' : 'Open Safari Settings',
                color: accent,
                onPressed: () => _openSafariSettings(context),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.flash_on_rounded, size: 18),
                label: Text(isRtl ? 'اختبار التحويل' : 'Test Interception'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: accent,
                  side: BorderSide(color: accent),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => _testDeepLink(context),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInfoCard({
    required bool isDark,
    required Color accent,
    required String title,
    required String description,
    required dynamic icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: isDark ? 0.1 : 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon is IconData)
            Icon(icon, color: accent, size: 28)
          else if (icon is FaIconData)
            FaIcon(icon, color: accent, size: 28)
          else
            Icon(Icons.extension_rounded, color: accent, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? AppTheme.textPrimary
                        : AppTheme.lightTextPrimary,
                    fontFamily: 'Space Grotesk',
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: isDark
                        ? AppTheme.textSecondary
                        : AppTheme.lightTextSecondary,
                    fontFamily: 'Inter',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepHeader(bool isDark, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
          fontFamily: 'Space Grotesk',
        ),
      ),
    );
  }

  Widget _buildStepItem(bool isDark, String number, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isDark ? AppTheme.surface : AppTheme.lightSurface,
              shape: BoxShape.circle,
              border: Border.all(
                color:
                    isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
              ),
            ),
            child: Text(
              number,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary,
                fontFamily: 'Inter',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
