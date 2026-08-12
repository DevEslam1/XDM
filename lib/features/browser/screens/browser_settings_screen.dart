import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/section_header.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/ad_blocker_service.dart';
import 'script_manager_screen.dart';

/// Centralized search engine definitions — single source of truth.
/// Used by both [BrowserSettingsScreen] and the browser navigation logic.
class SearchEngineConfig {
  final String name;
  final String searchUrlPrefix;

  const SearchEngineConfig({
    required this.name,
    required this.searchUrlPrefix,
  });

  static const List<SearchEngineConfig> engines = [
    SearchEngineConfig(
        name: 'Google', searchUrlPrefix: 'https://google.com/search?q='),
    SearchEngineConfig(
        name: 'DuckDuckGo', searchUrlPrefix: 'https://duckduckgo.com/?q='),
    SearchEngineConfig(
        name: 'Bing', searchUrlPrefix: 'https://www.bing.com/search?q='),
    SearchEngineConfig(
        name: 'Yahoo', searchUrlPrefix: 'https://search.yahoo.com/search?p='),
    SearchEngineConfig(
        name: 'Ecosia', searchUrlPrefix: 'https://www.ecosia.org/search?q='),
    SearchEngineConfig(
        name: 'Brave', searchUrlPrefix: 'https://search.brave.com/search?q='),
    SearchEngineConfig(
        name: 'Startpage',
        searchUrlPrefix: 'https://www.startpage.com/sp/search?query='),
  ];

  /// Returns the search URL prefix for [engineName], falling back to Google.
  static String prefixFor(String engineName) {
    return engines
        .firstWhere(
          (e) => e.name == engineName,
          orElse: () => engines.first,
        )
        .searchUrlPrefix;
  }

  /// Returns true if [engineName] is a recognized engine.
  static bool isValid(String engineName) {
    return engines.any((e) => e.name == engineName);
  }
}

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

    // Use centralized engine list; fallback to Google if stored value is invalid.
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
            lightPulse(settings);
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
                  icon: Icons.search_rounded,
                  color: accent,
                  isDark: isDark,
                ),
                title: Text(
                  L10n.isRtl(context)
                      ? 'محرك البحث الرئيسي'
                      : 'Default Search Engine',
                  style: TextStyle(
                      color: textClr,
                      fontWeight: FontWeight.w600,
                      fontSize: 14),
                ),
                subtitle: Text(
                  currentEngine,
                  style: TextStyle(color: subtitleClr, fontSize: 12),
                ),
                trailing: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: currentEngine,
                    dropdownColor:
                        isDark ? AppTheme.surface : AppTheme.lightSurface,
                    style: TextStyle(color: textClr, fontSize: 14),
                    icon: Icon(Icons.keyboard_arrow_down_rounded,
                        color: accent, size: 22),
                    borderRadius: BorderRadius.circular(14),
                    items: SearchEngineConfig.engines.map((engine) {
                      return DropdownMenuItem<String>(
                        value: engine.name,
                        child: Text(engine.name),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        lightPulse(settings);
                        settings.setSearchEngine(val);
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SectionHeader(
            title:
                L10n.isRtl(context) ? 'الأمان والخصوصية' : 'Privacy & Shield',
            subtitle: L10n.isRtl(context)
                ? 'تحكم في الحماية والخصوصية'
                : 'Control protection and privacy',
            icon: Icons.shield_rounded,
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
                  lightPulse(settings);
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
                  lightPulse(settings);
                  setState(() => _snifferEnabled = val);
                  widget.onSnifferChanged?.call(val);
                },
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
                  lightPulse(settings);
                  settings.setDesktopMode(val);
                },
              ),
              _divider(isDark),
              _buildSettingsSwitch(
                context: context,
                icon: Icons.zoom_in_rounded,
                title: L10n.isRtl(context) ? 'التقريب بالأصابع' : 'Pinch to Zoom',
                subtitle: L10n.isRtl(context)
                    ? 'السماح بالتقريب على جميع الصفحات'
                    : 'Allow zoom gesture on all web pages',
                value: settings.pinchToZoom,
                accent: accent,
                textClr: textClr,
                subtitleClr: subtitleClr,
                isDark: isDark,
                onChanged: (val) {
                  lightPulse(settings);
                  settings.setPinchToZoom(val);
                },
              ),
              _divider(isDark),
              _buildSettingsSwitch(
                context: context,
                icon: settings.forceDarkMode
                    ? Icons.dark_mode_rounded
                    : Icons.light_mode_outlined,
                title: L10n.isRtl(context)
                    ? 'الوضع الداكن الإجباري'
                    : 'Force Dark Mode',
                subtitle: L10n.isRtl(context)
                    ? 'تطبيق خلفية داكنة على جميع صفحات الويب'
                    : 'Apply dark themes to web content',
                value: settings.forceDarkMode,
                accent: accent,
                textClr: textClr,
                subtitleClr: subtitleClr,
                isDark: isDark,
                onChanged: (val) {
                  lightPulse(settings);
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
                  lightPulse(settings);
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
                  lightPulse(settings);
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
                  lightPulse(settings);
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
        color: value ? accent : subtitleClr,
        isDark: isDark,
      ),
      title: Text(
        title,
        style: TextStyle(
            color: textClr, fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: subtitleClr, fontSize: 12, height: 1.3),
      ),
      value: value,
      activeThumbColor: Colors.white,
      activeTrackColor: accent,
      inactiveThumbColor:
          isDark ? const Color(0xFF7F7F90) : const Color(0xFF94A3B8),
      inactiveTrackColor:
          isDark ? const Color(0x1AFFFFFF) : const Color(0x0D000000),
      trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => Colors.transparent),
      onChanged: onChanged,
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
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: color.withValues(alpha: 0.2),
          width: 0.7,
        ),
      ),
      child: Icon(icon, color: color, size: 18),
    );
  }
}