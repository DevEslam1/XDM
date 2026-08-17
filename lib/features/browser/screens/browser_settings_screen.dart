import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/section_header.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/ad_blocker_service.dart';
import '../services/search_engine_config.dart';
import 'script_manager_screen.dart';

/// Browser settings screen with search-engine picker, media sniffer toggle,
/// privacy features, max tabs slider, and web rendering options.
class BrowserSettingsScreen extends StatefulWidget {
  final bool isSnifferEnabled;
  final ValueChanged<bool>? onSnifferChanged;

  const BrowserSettingsScreen({
    super.key,
    this.isSnifferEnabled = true,
    this.onSnifferChanged,
  });

  @override
  State<BrowserSettingsScreen> createState() => _BrowserSettingsScreenState();
}

class _BrowserSettingsScreenState extends State<BrowserSettingsScreen>
    with HapticHelper {
  late bool _snifferEnabled;
  final AdBlockerService _adBlocker = AdBlockerService.instance;

  @override
  void initState() {
    super.initState();
    _snifferEnabled = widget.isSnifferEnabled;
    _adBlocker.addListener(_onAdBlockerStateChanged);
  }

  @override
  void didUpdateWidget(covariant BrowserSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isSnifferEnabled != widget.isSnifferEnabled &&
        _snifferEnabled != widget.isSnifferEnabled) {
      _snifferEnabled = widget.isSnifferEnabled;
    }
  }

  @override
  void dispose() {
    _adBlocker.removeListener(_onAdBlockerStateChanged);
    super.dispose();
  }

  void _onAdBlockerStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isAmoled = settings.isAmoledMode;
    final bgClr = isAmoled
        ? Colors.black
        : (isDark ? AppTheme.surface : AppTheme.lightSurface);
    final textClr = isDark ? Colors.white : Colors.black87;
    final subtitleClr = isDark ? Colors.white54 : Colors.black54;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    final currentEngine = SearchEngineConfig.isValid(settings.searchEngine)
        ? settings.searchEngine
        : 'Google';

    return Scaffold(
      backgroundColor: bgClr,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          L10n.isRtl(context) ? 'إعدادات المتصفح' : 'Browser Settings',
          style: TextStyle(
            color: textClr,
            fontSize: 18,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.2,
          ),
        ),
        centerTitle: false,
        leading: IconButton(
          icon: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.arrow_back_rounded, color: accent, size: 20),
          ),
          onPressed: () {
            HapticHelper.triggerHaptic(settings);
            Navigator.pop(context);
          },
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          SectionHeader(
            title: L10n.isRtl(context) ? 'البحث والأداء' : 'Search Engine',
            subtitle: L10n.isRtl(context)
                ? 'اختر محرك البحث الافتراضي'
                : 'Choose your default search provider',
            icon: Icons.search_rounded,
            isDark: isDark,
            accentColor: accent,
          ),
          const SizedBox(height: 10),
          SettingsCard(
            isDark: isDark,
            isAmoled: isAmoled,
            children: [
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                leading: _SettingIconBadge(
                  icon: Icons.travel_explore_rounded,
                  color: accent,
                  isDark: isDark,
                ),
                title: Text(
                  L10n.isRtl(context) ? 'محرك البحث' : 'Default Search Engine',
                  style: TextStyle(
                      color: textClr,
                      fontWeight: FontWeight.w600,
                      fontSize: 14),
                ),
                subtitle: Text(
                  currentEngine,
                  style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.bold,
                      fontSize: 12),
                ),
                trailing: PopupMenuButton<String>(
                  initialValue: currentEngine,
                  color: isDark ? AppTheme.cardBg : AppTheme.lightCardBg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: isDark
                          ? AppTheme.border.withValues(alpha: 0.5)
                          : AppTheme.lightBorder,
                    ),
                  ),
                  onSelected: (engine) {
                    HapticHelper.triggerHaptic(settings);
                    settings.setSearchEngine(engine);
                  },
                  itemBuilder: (context) => SearchEngineConfig.engines.map((e) {
                    return PopupMenuItem<String>(
                      value: e.name,
                      child: Row(
                        children: [
                          Icon(
                            e.name == currentEngine
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_off_rounded,
                            size: 16,
                            color: e.name == currentEngine
                                ? accent
                                : (isDark ? Colors.white38 : Colors.black38),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            e.name,
                            style: TextStyle(
                              color: e.name == currentEngine
                                  ? textClr
                                  : subtitleClr,
                              fontWeight: e.name == currentEngine
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          currentEngine,
                          style: TextStyle(
                            color: accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.arrow_drop_down_rounded,
                            color: accent, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SectionHeader(
            title: L10n.isRtl(context)
                ? 'الحماية والخصوصية'
                : 'Privacy & Security',
            subtitle: L10n.isRtl(context)
                ? 'إعدادات الأمان ومنع التتبع وحفظ السجل'
                : 'Ad blocker, sniffer, history & anti-tracking',
            icon: Icons.security_rounded,
            isDark: isDark,
            accentColor: accent,
          ),
          const SizedBox(height: 10),
          SettingsCard(
            isDark: isDark,
            isAmoled: isAmoled,
            children: [
              _buildSettingsSwitch(
                context: context,
                icon: _adBlocker.isEnabled
                    ? Icons.shield_rounded
                    : Icons.shield_outlined,
                title: L10n.isRtl(context) ? 'مانع الإعلانات' : 'Ad Blocker',
                subtitle: L10n.isRtl(context)
                    ? 'حجب الإعلانات والنوافذ المنبثقة التلقائية'
                    : 'Block ads, popups & trackers',
                value: _adBlocker.isEnabled,
                accent: accent,
                textClr: textClr,
                subtitleClr: subtitleClr,
                isDark: isDark,
                onChanged: (val) {
                  HapticHelper.triggerHaptic(settings);
                  _adBlocker.setEnabled(val);
                },
              ),
              _divider(isDark),
              _buildSettingsSwitch(
                context: context,
                icon: _snifferEnabled
                    ? Icons.radar_rounded
                    : Icons.radar_outlined,
                title: L10n.isRtl(context) ? 'كاشف الوسائط' : 'Media Sniffer',
                subtitle: L10n.isRtl(context)
                    ? 'الكشف عن الفيديوهات وملفات الصوت للتحميل'
                    : 'Detect downloadable videos & audio',
                value: _snifferEnabled,
                accent: accent,
                textClr: textClr,
                subtitleClr: subtitleClr,
                isDark: isDark,
                onChanged: (val) {
                  HapticHelper.triggerHaptic(settings);
                  setState(() => _snifferEnabled = val);
                  widget.onSnifferChanged?.call(val);
                },
              ),
              _divider(isDark),
              _buildSettingsSwitch(
                context: context,
                icon: Icons.history_toggle_off_rounded,
                title: L10n.isRtl(context) ? 'حفظ السجل' : 'Save Browsing History',
                subtitle: L10n.isRtl(context)
                    ? 'تسجيل المواقع المزارة في السجل'
                    : 'Keep record of visited websites',
                value: settings.saveBrowserHistory,
                accent: accent,
                textClr: textClr,
                subtitleClr: subtitleClr,
                isDark: isDark,
                onChanged: (val) {
                  HapticHelper.triggerHaptic(settings);
                  settings.setSaveBrowserHistory(val);
                },
              ),
              _divider(isDark),
              _buildSettingsSwitch(
                context: context,
                icon: Icons.lock_outline_rounded,
                title: L10n.isRtl(context) ? 'الاتصال الآمن فقط (HTTPS)' : 'HTTPS-Only Mode',
                subtitle: L10n.isRtl(context)
                    ? 'ترقية جميع الاتصالات إلى HTTPS المشفر'
                    : 'Upgrade insecure HTTP requests to HTTPS',
                value: settings.httpsOnly,
                accent: accent,
                textClr: textClr,
                subtitleClr: subtitleClr,
                isDark: isDark,
                onChanged: (val) {
                  HapticHelper.triggerHaptic(settings);
                  settings.setHttpsOnly(val);
                },
              ),
              _divider(isDark),
              _buildSettingsSwitch(
                context: context,
                icon: Icons.fingerprint_rounded,
                title: L10n.isRtl(context) ? 'مقاومة التتبع الرقمي' : 'Anti-Fingerprinting',
                subtitle: L10n.isRtl(context)
                    ? 'حماية هوية المتصفح من التعقب'
                    : 'Shield canvas, audio & navigator fingerprinting',
                value: settings.antiFingerprinting,
                accent: accent,
                textClr: textClr,
                subtitleClr: subtitleClr,
                isDark: isDark,
                onChanged: (val) {
                  HapticHelper.triggerHaptic(settings);
                  settings.setAntiFingerprinting(val);
                },
              ),
              _divider(isDark),
              _buildSettingsSwitch(
                context: context,
                icon: Icons.password_rounded,
                title: L10n.isRtl(context) ? 'الملء التلقائي للنماذج' : 'Form Autofill',
                subtitle: L10n.isRtl(context)
                    ? 'حفظ وتعبئة الحقول والنماذج تلقائياً'
                    : 'Save & autofill login credentials and inputs',
                value: settings.formAutofill,
                accent: accent,
                textClr: textClr,
                subtitleClr: subtitleClr,
                isDark: isDark,
                onChanged: (val) {
                  HapticHelper.triggerHaptic(settings);
                  settings.setFormAutofill(val);
                },
              ),
            ],
          ),
          const SizedBox(height: 24),
          SectionHeader(
            title: L10n.isRtl(context) ? 'علامات التبويب والموارد' : 'Tabs & Resource Management',
            subtitle: L10n.isRtl(context)
                ? 'الحد الأقصى للألسنة وإدارة الذاكرة'
                : 'Maximum tabs limit and memory allocation',
            icon: Icons.tab_rounded,
            isDark: isDark,
            accentColor: accent,
          ),
          const SizedBox(height: 10),
          SettingsCard(
            isDark: isDark,
            isAmoled: isAmoled,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            _SettingIconBadge(
                              icon: Icons.layers_rounded,
                              color: accent,
                              isDark: isDark,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              L10n.isRtl(context) ? 'أقصى عدد للألسنة' : 'Max Open Tabs',
                              style: TextStyle(
                                color: textClr,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${settings.maxTabs}',
                            style: TextStyle(
                              color: accent,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Slider(
                      value: settings.maxTabs.toDouble().clamp(4.0, 30.0),
                      min: 4.0,
                      max: 30.0,
                      divisions: 26,
                      activeColor: accent,
                      inactiveColor: isDark ? Colors.white12 : Colors.black12,
                      onChanged: (v) {
                        HapticHelper.triggerHaptic(settings);
                        settings.maxTabs = v.round();
                      },
                    ),
                    Text(
                      L10n.isRtl(context)
                          ? 'عند تجاوز الحد، يتم تعليق الألسنة غير النشطة لتوفير الذاكرة'
                          : 'Inactive tabs are suspended when exceeding limit to preserve RAM',
                      style: TextStyle(color: subtitleClr, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SectionHeader(
            title: L10n.isRtl(context)
                ? 'العرض والتصفح'
                : 'Display & Web Rendering',
            subtitle: L10n.isRtl(context)
                ? 'تخصيص طريقة عرض الصفحات'
                : 'Customize page rendering options',
            icon: Icons.tune_rounded,
            isDark: isDark,
            accentColor: accent,
          ),
          const SizedBox(height: 10),
          SettingsCard(
            isDark: isDark,
            isAmoled: isAmoled,
            children: [
              _buildSettingsSwitch(
                context: context,
                icon: settings.desktopMode
                    ? Icons.desktop_mac_rounded
                    : Icons.smartphone_rounded,
                title: L10n.isRtl(context) ? 'وضع سطح المكتب' : 'Desktop Mode',
                subtitle: L10n.isRtl(context)
                    ? 'طلب نسَخ سطح المكتب من المواقع تلقائياً'
                    : 'Request desktop version of websites',
                value: settings.desktopMode,
                accent: accent,
                textClr: textClr,
                subtitleClr: subtitleClr,
                isDark: isDark,
                onChanged: (val) {
                  HapticHelper.triggerHaptic(settings);
                  settings.setDesktopMode(val);
                },
              ),
              _divider(isDark),
              _buildSettingsSwitch(
                context: context,
                icon: Icons.zoom_in_rounded,
                title:
                    L10n.isRtl(context) ? 'التقريب بالأصابع' : 'Pinch to Zoom',
                subtitle: L10n.isRtl(context)
                    ? 'السماح بالتقريب على جميع الصفحات'
                    : 'Allow zoom gesture on all web pages',
                value: settings.pinchToZoom,
                accent: accent,
                textClr: textClr,
                subtitleClr: subtitleClr,
                isDark: isDark,
                onChanged: (val) {
                  HapticHelper.triggerHaptic(settings);
                  settings.setPinchToZoom(val);
                },
              ),
              _divider(isDark),
              _buildSettingsSwitch(
                context: context,
                icon: settings.forceDarkMode
                    ? Icons.dark_mode_rounded
                    : Icons.light_mode_outlined,
                title: L10n.of(context, 'browser_force_dark_mode'),
                subtitle: L10n.of(context, 'browser_force_dark_mode_sub'),
                value: settings.forceDarkMode,
                accent: accent,
                textClr: textClr,
                subtitleClr: subtitleClr,
                isDark: isDark,
                onChanged: (val) {
                  HapticHelper.triggerHaptic(settings);
                  settings.setForceDarkMode(val);
                },
              ),
              _divider(isDark),
              _buildSettingsSwitch(
                context: context,
                icon: settings.blockImages
                    ? Icons.hide_image_rounded
                    : Icons.image_rounded,
                title: L10n.isRtl(context) ? 'حظر الصور' : 'Block Images',
                subtitle: L10n.isRtl(context)
                    ? 'توفير البيانات وعدم تحميل الصور'
                    : 'Save data by hiding web images',
                value: settings.blockImages,
                accent: accent,
                textClr: textClr,
                subtitleClr: subtitleClr,
                isDark: isDark,
                onChanged: (val) {
                  HapticHelper.triggerHaptic(settings);
                  settings.setBlockImages(val);
                },
              ),
              _divider(isDark),
              _buildSettingsSwitch(
                context: context,
                icon: Icons.open_in_new_rounded,
                title: L10n.isRtl(context)
                    ? 'فتح الروابط في التطبيقات'
                    : 'Open Links in External App',
                subtitle: L10n.isRtl(context)
                    ? 'توجيه روابط التطبيقات المخصصة تلقائياً'
                    : 'Open app-specific URLs in external apps',
                value: settings.openLinksInApp,
                accent: accent,
                textClr: textClr,
                subtitleClr: subtitleClr,
                isDark: isDark,
                onChanged: (val) {
                  HapticHelper.triggerHaptic(settings);
                  settings.setOpenLinksInApp(val);
                },
              ),
            ],
          ),
          const SizedBox(height: 24),
          SectionHeader(
            title: L10n.isRtl(context)
                ? 'أدوات المطورين والسكربتات'
                : 'Developer & Scripts',
            subtitle: L10n.isRtl(context)
                ? 'إدارة السكربتات والأنماط المخصصة'
                : 'Manage custom scripts and styles',
            icon: Icons.code_rounded,
            isDark: isDark,
            accentColor: accent,
          ),
          const SizedBox(height: 10),
          SettingsCard(
            isDark: isDark,
            isAmoled: isAmoled,
            children: [
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                leading: _SettingIconBadge(
                  icon: Icons.code_rounded,
                  color: accent,
                  isDark: isDark,
                ),
                title: Text(
                  L10n.isRtl(context)
                      ? 'سكربتات و CSS مخصص'
                      : 'Custom JS & CSS Scripts',
                  style: TextStyle(
                      color: textClr,
                      fontWeight: FontWeight.w600,
                      fontSize: 14),
                ),
                subtitle: Text(
                  L10n.isRtl(context)
                      ? 'إدارة وحقن كود JavaScript/CSS مخصص للصفحات'
                      : 'Inject user scripts & styles into web pages',
                  style: TextStyle(color: subtitleClr, fontSize: 12),
                ),
                trailing: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.chevron_right_rounded,
                      color: accent, size: 20),
                ),
                onTap: () {
                  HapticHelper.triggerHaptic(settings);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ScriptManagerScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: subtitleClr.withValues(alpha: 0.6),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    L10n.isRtl(context)
                        ? 'يتم حفظ التغييرات تلقائياً'
                        : 'Changes are saved automatically',
                    style: TextStyle(
                      color: subtitleClr.withValues(alpha: 0.7),
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(bool isDark) => Divider(
        height: 1,
        thickness: 0.5,
        indent: 56,
        endIndent: 16,
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.06),
      );

  Widget _buildSettingsSwitch({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required Color accent,
    required Color textClr,
    required Color subtitleClr,
    required bool isDark,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      secondary: _SettingIconBadge(
        icon: icon,
        color: value
            ? accent
            : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted),
        isDark: isDark,
      ),
      title: Text(
        title,
        style: TextStyle(
          color: textClr,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: subtitleClr,
          fontSize: 12,
        ),
      ),
      activeThumbColor: accent,
      value: value,
      onChanged: onChanged,
    );
  }
}

class SettingsCard extends StatelessWidget {
  final List<Widget> children;
  final bool isDark;
  final bool isAmoled;

  const SettingsCard({
    super.key,
    required this.children,
    required this.isDark,
    this.isAmoled = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isAmoled
        ? const Color(0xFF0A0A0A)
        : (isDark ? AppTheme.cardBg : AppTheme.lightCardBg);
    final borderClr = isDark
        ? AppTheme.border.withValues(alpha: 0.4)
        : AppTheme.lightBorder;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderClr, width: 0.8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          children: children,
        ),
      ),
    );
  }
}

class _SettingIconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final bool isDark;

  const _SettingIconBadge({
    required this.icon,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }
}
