import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/ad_blocker_service.dart';
import 'script_manager_screen.dart';

class BrowserSettingsScreen extends StatefulWidget with HapticHelper {
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

  static const List<String> _searchEngines = [
    'Google',
    'DuckDuckGo',
    'Bing',
    'Yahoo',
    'Ecosia',
    'Brave',
    'Startpage',
  ];

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isAmoled = settings.isAmoledMode;
    final bgClr = isAmoled
        ? Colors.black
        : (isDark ? AppTheme.surface : AppTheme.lightSurface);
    final cardClr = isDark
        ? AppTheme.surface.withValues(alpha: 0.8)
        : AppTheme.lightSurface;
    final textClr = isDark ? Colors.white : Colors.black87;
    final subtitleClr = isDark ? Colors.white54 : Colors.black54;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return Scaffold(
      backgroundColor: bgClr,
      appBar: AppBar(
        backgroundColor: bgClr,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          L10n.isRtl(context) ? 'إعدادات المتصفح' : 'Browser Settings',
          style: TextStyle(
            color: textClr,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: textClr),
          onPressed: () {
            lightPulse(settings);
            Navigator.pop(context);
          },
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          _buildSectionHeader(
            context,
            L10n.isRtl(context) ? 'البحث والأداء' : 'Search Engine',
            accent,
          ),
          const SizedBox(height: 8),
          _buildCardContainer(
            cardClr: cardClr,
            isDark: isDark,
            children: [
              ListTile(
                leading: Icon(Icons.search_rounded, color: accent),
                title: Text(
                  L10n.isRtl(context) ? 'محرك البحث الرئيسي' : 'Default Search Engine',
                  style: TextStyle(color: textClr, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  settings.searchEngine,
                  style: TextStyle(color: subtitleClr, fontSize: 13),
                ),
                trailing: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _searchEngines.contains(settings.searchEngine)
                        ? settings.searchEngine
                        : 'Google',
                    dropdownColor: cardClr,
                    style: TextStyle(color: textClr, fontSize: 14),
                    icon: Icon(Icons.keyboard_arrow_down, color: accent),
                    items: _searchEngines.map((engine) {
                      return DropdownMenuItem<String>(
                        value: engine,
                        child: Text(engine),
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
          const SizedBox(height: 20),
          _buildSectionHeader(
            context,
            L10n.isRtl(context) ? 'الأمان والخصوصية' : 'Privacy & Shield',
            accent,
          ),
          const SizedBox(height: 8),
          _buildCardContainer(
            cardClr: cardClr,
            isDark: isDark,
            children: [
              SwitchListTile(
                secondary: Icon(
                  _adBlocker.isEnabled ? Icons.shield : Icons.shield_outlined,
                  color: _adBlocker.isEnabled ? accent : subtitleClr,
                ),
                title: Text(
                  L10n.isRtl(context) ? 'مانع الإعلانات' : 'Ad Blocker',
                  style: TextStyle(color: textClr, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  L10n.isRtl(context)
                      ? 'حجب الإعلانات والنوافذ المنبثقة التلقائية'
                      : 'Block ads, popups & trackers',
                  style: TextStyle(color: subtitleClr, fontSize: 12),
                ),
                value: _adBlocker.isEnabled,
                activeThumbColor: accent,
                onChanged: (val) {
                  lightPulse(settings);
                  _adBlocker.setEnabled(val);
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: Icon(
                  _snifferEnabled ? Icons.radar : Icons.radar_outlined,
                  color: _snifferEnabled ? accent : subtitleClr,
                ),
                title: Text(
                  L10n.isRtl(context) ? 'كاشف الوسائط' : 'Media Sniffer',
                  style: TextStyle(color: textClr, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  L10n.isRtl(context)
                      ? 'الكشف عن الفيديوهات وملفات الصوت للتحميل'
                      : 'Detect downloadable videos & audio',
                  style: TextStyle(color: subtitleClr, fontSize: 12),
                ),
                value: _snifferEnabled,
                activeThumbColor: accent,
                onChanged: (val) {
                  lightPulse(settings);
                  setState(() => _snifferEnabled = val);
                  widget.onSnifferChanged?.call(val);
                },
              ),
            ],
          ),
          const SizedBox(height: 20),
          _buildSectionHeader(
            context,
            L10n.isRtl(context) ? 'العرض والتصفح' : 'Display & Web Rendering',
            accent,
          ),
          const SizedBox(height: 8),
          _buildCardContainer(
            cardClr: cardClr,
            isDark: isDark,
            children: [
              SwitchListTile(
                secondary: Icon(
                  settings.desktopMode ? Icons.desktop_mac : Icons.smartphone,
                  color: settings.desktopMode ? accent : subtitleClr,
                ),
                title: Text(
                  L10n.isRtl(context) ? 'وضع سطح المكتب' : 'Desktop Mode',
                  style: TextStyle(color: textClr, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  L10n.isRtl(context)
                      ? 'طلب نسَخ سطح المكتب من المواقع تلقائياً'
                      : 'Request desktop version of websites',
                  style: TextStyle(color: subtitleClr, fontSize: 12),
                ),
                value: settings.desktopMode,
                activeThumbColor: accent,
                onChanged: (val) {
                  lightPulse(settings);
                  settings.setDesktopMode(val);
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: Icon(
                  Icons.zoom_in_rounded,
                  color: settings.pinchToZoom ? accent : subtitleClr,
                ),
                title: Text(
                  L10n.isRtl(context) ? 'التقريب بالأصابع' : 'Pinch to Zoom',
                  style: TextStyle(color: textClr, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  L10n.isRtl(context)
                      ? 'السماح بالتقريب على جميع الصفحات'
                      : 'Allow zoom gesture on all web pages',
                  style: TextStyle(color: subtitleClr, fontSize: 12),
                ),
                value: settings.pinchToZoom,
                activeThumbColor: accent,
                onChanged: (val) {
                  lightPulse(settings);
                  settings.setPinchToZoom(val);
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: Icon(
                  settings.forceDarkMode
                      ? Icons.dark_mode_rounded
                      : Icons.light_mode_outlined,
                  color: settings.forceDarkMode ? accent : subtitleClr,
                ),
                title: Text(
                  L10n.isRtl(context) ? 'الوضع الداكن الإجباري' : 'Force Dark Mode',
                  style: TextStyle(color: textClr, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  L10n.isRtl(context)
                      ? 'تطبيق خلفية داكنة على جميع صفحات الويب'
                      : 'Apply dark themes to web content',
                  style: TextStyle(color: subtitleClr, fontSize: 12),
                ),
                value: settings.forceDarkMode,
                activeThumbColor: accent,
                onChanged: (val) {
                  lightPulse(settings);
                  settings.setForceDarkMode(val);
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: Icon(
                  settings.blockImages
                      ? Icons.hide_image_rounded
                      : Icons.image_rounded,
                  color: settings.blockImages ? accent : subtitleClr,
                ),
                title: Text(
                  L10n.isRtl(context) ? 'حظر الصور' : 'Block Images',
                  style: TextStyle(color: textClr, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  L10n.isRtl(context)
                      ? 'توفير البيانات وعدم تحميل الصور'
                      : 'Save data by hiding web images',
                  style: TextStyle(color: subtitleClr, fontSize: 12),
                ),
                value: settings.blockImages,
                activeThumbColor: accent,
                onChanged: (val) {
                  lightPulse(settings);
                  settings.setBlockImages(val);
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: Icon(
                  Icons.open_in_new_rounded,
                  color: settings.openLinksInApp ? accent : subtitleClr,
                ),
                title: Text(
                  L10n.isRtl(context)
                      ? 'فتح الروابط في التطبيقات'
                      : 'Open Links in External App',
                  style: TextStyle(color: textClr, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  L10n.isRtl(context)
                      ? 'توجيه روابط التطبيقات المخصصة تلقائياً'
                      : 'Open app-specific URLs in external apps',
                  style: TextStyle(color: subtitleClr, fontSize: 12),
                ),
                value: settings.openLinksInApp,
                activeThumbColor: accent,
                onChanged: (val) {
                  lightPulse(settings);
                  settings.setOpenLinksInApp(val);
                },
              ),
            ],
          ),
          const SizedBox(height: 20),
          _buildSectionHeader(
            context,
            L10n.isRtl(context) ? 'أدوات المطورين والسكربتات' : 'Developer & Scripts',
            accent,
          ),
          const SizedBox(height: 8),
          _buildCardContainer(
            cardClr: cardClr,
            isDark: isDark,
            children: [
              ListTile(
                leading: Icon(Icons.code_rounded, color: accent),
                title: Text(
                  L10n.isRtl(context)
                      ? 'سكربتات و CSS مخصص'
                      : 'Custom JS & CSS Scripts',
                  style: TextStyle(color: textClr, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  L10n.isRtl(context)
                      ? 'إدارة وحقن كود JavaScript/CSS مخصص للصفحات'
                      : 'Inject user scripts & styles into web pages',
                  style: TextStyle(color: subtitleClr, fontSize: 12),
                ),
                trailing: Icon(Icons.chevron_right_rounded, color: subtitleClr),
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
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title, Color accent) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4),
      child: Text(
        title,
        style: TextStyle(
          color: accent,
          fontSize: 13,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildCardContainer({
    required Color cardClr,
    required bool isDark,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: cardClr,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? AppTheme.glassBorder.withValues(alpha: 0.3)
              : AppTheme.lightGlassBorder.withValues(alpha: 0.5),
          width: 0.8,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}
