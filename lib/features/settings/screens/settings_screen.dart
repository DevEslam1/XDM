import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/responsive.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/empty_state_view.dart';
import '../provider/settings_provider.dart';
import '../../downloads/provider/download_provider.dart';
import 'appearance_settings_page.dart';
import 'downloads_settings_page.dart';
import 'network_settings_page.dart';
import 'notifications_settings_page.dart';
import 'torrent_settings_page.dart';
import 'power_settings_page.dart';
import 'advanced_settings_page.dart';
import '../widgets/settings_tiles.dart';
import '../widgets/browser_extensions_sheet.dart';

Color getSettingsTabColor(int tabIndex, bool isDark) {
  return switch (tabIndex) {
    0 => isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
    1 => isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
    2 => isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan,
    3 => isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
    4 => isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
    5 => isDark ? AppTheme.neonOrange : AppTheme.lightNeonOrange,
    6 => isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
    _ => isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
  };
}

class _SettingSearchEntry {
  final String categoryTitle;
  final int categoryIndex;
  final String settingTitle;
  final String? subtitle;
  final List<String> keywords;
  final Widget Function(BuildContext context) builder;
  final Color accentColor;

  const _SettingSearchEntry({
    required this.categoryTitle,
    required this.categoryIndex,
    required this.settingTitle,
    this.subtitle,
    this.keywords = const [],
    required this.builder,
    required this.accentColor,
  });

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    if (categoryTitle.toLowerCase().contains(q)) return true;
    if (settingTitle.toLowerCase().contains(q)) return true;
    if (subtitle?.toLowerCase().contains(q) ?? false) return true;
    return keywords.any((k) => k.toLowerCase().contains(q));
  }
}

class SettingsScreen extends StatefulWidget {
  final String? initialSection;
  const SettingsScreen({super.key, this.initialSection});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with HapticHelper, SingleTickerProviderStateMixin {
  late int _selectedCategoryIndex;
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;
  String _searchQuery = '';
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _selectedCategoryIndex = _mapSectionToIndex(widget.initialSection);
    _searchController = TextEditingController();
    _searchFocusNode = FocusNode();
    _pageController = PageController(initialPage: _selectedCategoryIndex);

    _searchController.addListener(() {
      if (mounted) {
        setState(() {
          _searchQuery = _searchController.text.trim().toLowerCase();
        });
      }
    });

    _searchFocusNode.addListener(() {
      if (mounted) setState(() {});
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context
            .read<SettingsProvider>()
            .setActiveSettingsTabIndex(_selectedCategoryIndex);
      }
    });
  }

  int _mapSectionToIndex(String? section) {
    if (section == null) return 0;
    final s = section.toLowerCase().trim();
    if (s.contains('appear') ||
        s.contains('visual') ||
        s.contains('theme') ||
        s == '07') {
      return 0;
    }
    if (s.contains('download') ||
        s.contains('engine') ||
        s.contains('bandwidth') ||
        s == '01' ||
        s == '02') {
      return 1;
    }
    if (s.contains('net') ||
        s.contains('proxy') ||
        s.contains('dns') ||
        s.contains('sec') ||
        s == '03' ||
        s == '08') {
      return 2;
    }
    if (s.contains('notif') || s.contains('alert') || s == '04') return 3;
    if (s.contains('torrent') || s == '05') return 4;
    if (s.contains('power') || s.contains('perf') || s.contains('battery')) {
      return 5;
    }
    if (s.contains('adv') ||
        s.contains('back') ||
        s.contains('comm') ||
        s == '06' ||
        s == '09') {
      return 6;
    }
    return 0;
  }

  void _onCategorySelected(int index) {
    if (index == _selectedCategoryIndex) return;
    setState(() => _selectedCategoryIndex = index);
    if (_pageController.hasClients) {
      _pageController.jumpToPage(index);
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.setActiveSettingsTabIndex(index);
    triggerHaptic(settings);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _pageController.dispose();
    super.dispose();
  }

  List<_SettingSearchEntry> _buildSearchIndex(
    BuildContext context,
    SettingsProvider settings,
    bool isDark,
    bool isRtl,
  ) {
    final amber = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    final orange = isDark ? AppTheme.neonOrange : AppTheme.lightNeonOrange;
    final blue = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final cyan = isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan;
    final violet = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final green = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final red = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;

    return [
      // Category 0: Appearance
      _SettingSearchEntry(
        categoryTitle: isRtl ? 'المظهر والواجهة' : 'Appearance & UI',
        categoryIndex: 0,
        settingTitle: isRtl ? 'وضع المظهر' : 'Theme Mode',
        subtitle: isRtl
            ? 'فاتح / داكن / أسود (AMOLED) / تتبع النظام'
            : 'Light / Dark / AMOLED / Follow System',
        keywords: const [
          'theme',
          'dark',
          'light',
          'amoled',
          'black',
          'mode',
          'system',
          'color'
        ],
        accentColor: amber,
        builder: (ctx) => DropdownTile<String>(
          accentColor: amber,
          title: isRtl ? 'وضع المظهر' : 'Theme Mode',
          subtitle: isRtl
              ? 'فاتح / داكن / أسود (AMOLED) / تتبع النظام'
              : 'Light / Dark / AMOLED / Follow System',
          value: settings.themeMode,
          items: const ['light', 'dark', 'amoled', 'system'],
          itemLabels: const {
            'light': 'LIGHT',
            'dark': 'DARK',
            'amoled': 'AMOLED',
            'system': 'SYSTEM',
          },
          onChanged: (val) => val != null ? settings.setThemeMode(val) : null,
        ),
      ),
      _SettingSearchEntry(
        categoryTitle: isRtl ? 'المظهر والواجهة' : 'Appearance & UI',
        categoryIndex: 0,
        settingTitle: L10n.of(context, 'settings_classic_ui'),
        subtitle: L10n.of(context, 'settings_classic_ui_sub'),
        keywords: const ['classic', 'glass', 'ui', 'mode'],
        accentColor: amber,
        builder: (ctx) => SwitchTile(
          accentColor: amber,
          title: L10n.of(ctx, 'settings_classic_ui'),
          subtitle: L10n.of(ctx, 'settings_classic_ui_sub'),
          value: settings.classicUi,
          batterySaverOverride: settings.batterySaverMode,
          onChanged: (val) => settings.setClassicUi(val),
        ),
      ),
      _SettingSearchEntry(
        categoryTitle: isRtl ? 'المظهر والواجهة' : 'Appearance & UI',
        categoryIndex: 0,
        settingTitle: 'Neon Glow Effects',
        subtitle: 'Enable glowing neon accents on buttons',
        keywords: const ['glow', 'neon', 'effect', 'visual'],
        accentColor: amber,
        builder: (ctx) => SwitchTile(
          accentColor: amber,
          title: 'Neon Glow Effects',
          subtitle: 'Enable glowing neon accents on buttons',
          value: settings.enableGlow,
          onChanged: (val) => settings.setEnableGlow(val),
        ),
      ),

      // Category 1: Downloads
      _SettingSearchEntry(
        categoryTitle: isRtl ? 'التحميلات والتكامل' : 'Downloads & Plugins',
        categoryIndex: 1,
        settingTitle: isRtl ? 'ملحقات المتصفح (Firefox & Safari)' : 'Browser Plugins (Firefox & Safari)',
        subtitle: isRtl
            ? 'إلغاء تنزيلات المتصفح تلقائياً وتحويلها إلى XDM'
            : 'Auto-intercept & redirect downloads from Firefox Android & Safari iOS',
        keywords: const [
          'firefox',
          'safari',
          'browser',
          'extension',
          'plugin',
          'intercept',
          'redirect',
          'chrome',
          'download'
        ],
        accentColor: blue,
        builder: (ctx) => ActionTile(
          accentColor: blue,
          icon: Icons.extension_rounded,
          title: isRtl
              ? 'إعداد ملحقات المتصفح (Firefox & Safari)'
              : 'Browser Plugins (Firefox & Safari)',
          subtitle: isRtl
              ? 'إلغاء تنزيلات المتصفح تلقائياً وتحويلها إلى XDM'
              : 'Auto-intercept & redirect downloads from Firefox Android & Safari iOS',
          onTap: () => BrowserExtensionsSheet.show(ctx),
        ),
      ),
      _SettingSearchEntry(
        categoryTitle: isRtl ? 'التحميلات (المحرك)' : 'Downloads (Engine)',
        categoryIndex: 1,
        settingTitle: L10n.of(context, 'settings_auto_resume'),
        subtitle: L10n.of(context, 'settings_auto_resume_sub'),
        keywords: const ['auto', 'resume', 'start', 'reconnect'],
        accentColor: blue,
        builder: (ctx) => SwitchTile(
          accentColor: blue,
          title: L10n.of(ctx, 'settings_auto_resume'),
          subtitle: L10n.of(ctx, 'settings_auto_resume_sub'),
          value: settings.autoStart,
          onChanged: (val) => settings.setAutoStart(val),
        ),
      ),
      _SettingSearchEntry(
        categoryTitle: isRtl ? 'التحميلات (المحرك)' : 'Downloads (Engine)',
        categoryIndex: 1,
        settingTitle: L10n.of(context, 'settings_max_channels'),
        subtitle: L10n.of(context, 'settings_max_channels_sub'),
        keywords: const ['max', 'concurrent', 'downloads', 'channels'],
        accentColor: blue,
        builder: (ctx) => DropdownTile<int>(
          accentColor: blue,
          title: L10n.of(ctx, 'settings_max_channels'),
          subtitle: L10n.of(ctx, 'settings_max_channels_sub'),
          value: settings.maxDownloads,
          items: const [1, 2, 3, 5, 8],
          batterySaverOverride: settings.batterySaverMode,
          onChanged: (val) =>
              val != null ? settings.setMaxDownloads(val) : null,
        ),
      ),
      _SettingSearchEntry(
        categoryTitle: isRtl ? 'التحميلات (المحرك)' : 'Downloads (Engine)',
        categoryIndex: 1,
        settingTitle: L10n.of(context, 'settings_speed_limit'),
        subtitle: L10n.of(context, 'settings_speed_limit_sub'),
        keywords: const ['speed', 'limit', 'bandwidth', 'throttle', 'mb'],
        accentColor: blue,
        builder: (ctx) => SliderTile(
          accentColor: blue,
          title: L10n.of(ctx, 'settings_speed_limit'),
          subtitle: '${settings.speedLimitMb} MB/s',
          value: settings.speedLimitMb,
          min: 0,
          max: 100,
          divisions: 100,
          onChanged: (val) => settings.setSpeedLimit(val),
        ),
      ),

      // Category 2: Network & Security
      _SettingSearchEntry(
        categoryTitle: isRtl ? 'الشبكة والأمان' : 'Network & Security',
        categoryIndex: 2,
        settingTitle: L10n.of(context, 'settings_proxy'),
        subtitle: L10n.of(context, 'settings_proxy_sub'),
        keywords: const ['proxy', 'host', 'port', 'socks', 'http'],
        accentColor: cyan,
        builder: (ctx) => SwitchTile(
          accentColor: cyan,
          title: L10n.of(ctx, 'settings_proxy'),
          subtitle: L10n.of(ctx, 'settings_proxy_sub'),
          value: settings.enableProxy,
          onChanged: (val) => settings.setEnableProxy(val),
        ),
      ),

      // Category 3: Notifications
      _SettingSearchEntry(
        categoryTitle:
            isRtl ? 'الإشعارات والتنبيهات' : 'Notifications & Alerts',
        categoryIndex: 3,
        settingTitle: 'Global Notifications',
        subtitle: 'Show download progress bars in system tray',
        keywords: const [
          'notification',
          'alert',
          'chime',
          'sound',
          'haptics',
          'quiet'
        ],
        accentColor: violet,
        builder: (ctx) => SwitchTile(
          accentColor: violet,
          title: 'Global Notifications',
          subtitle: 'Show download progress bars in system tray',
          value: settings.notificationsEnabled,
          onChanged: (val) => settings.setNotificationsEnabled(val),
        ),
      ),

      // Category 4: Torrent
      _SettingSearchEntry(
        categoryTitle: isRtl ? 'التورنت (Torrent)' : 'Torrent',
        categoryIndex: 4,
        settingTitle: 'Enable DHT',
        subtitle: 'Peer discovery via decentralized DHT network',
        keywords: const [
          'torrent',
          'dht',
          'upnp',
          'nat-pmp',
          'pex',
          'lpd',
          'seeding',
          'ratio',
          'sequential'
        ],
        accentColor: green,
        builder: (ctx) => SwitchTile(
          accentColor: green,
          title: 'Enable DHT',
          subtitle: 'Peer discovery via decentralized DHT network',
          value: settings.enableDht,
          onChanged: (val) => settings.setEnableDht(val),
        ),
      ),

      // Category 5: Power & Performance
      _SettingSearchEntry(
        categoryTitle: isRtl ? 'الأداء والطاقة' : 'Power & Performance',
        categoryIndex: 5,
        settingTitle: 'Battery Saver Mode',
        subtitle:
            'Limits downloads to 1, threads to 2, and forces Classic UI mode',
        keywords: const [
          'power',
          'performance',
          'battery',
          'saver',
          'jank',
          'thermal',
          'isolate',
          'threads'
        ],
        accentColor: orange,
        builder: (ctx) => SwitchTile(
          accentColor: orange,
          title: 'Battery Saver Mode',
          subtitle:
              'Limits downloads to 1, threads to 2, and forces Classic UI mode',
          value: settings.batterySaverMode,
          onChanged: (val) => settings.setBatterySaverMode(val),
        ),
      ),

      // Category 2: Network — AdBlocker entry
      _SettingSearchEntry(
        categoryTitle: isRtl ? 'الشبكة والأمان' : 'Network & Security',
        categoryIndex: 2,
        settingTitle: L10n.of(context, 'settings_update_adblock_hosts'),
        subtitle: L10n.of(context, 'settings_enable_adblock_sub'),
        keywords: const [
          'adblock',
          'ad',
          'block',
          'hosts',
          'filter',
          'easylist',
          'tracking',
          'update'
        ],
        accentColor: cyan,
        builder: (ctx) => const NetworkSettingsPage(),
      ),

      // Category 6: Advanced
      _SettingSearchEntry(
        categoryTitle: isRtl ? 'متقدم وتطوير' : 'Advanced',
        categoryIndex: 6,
        settingTitle: 'Enable Developer Mode',
        subtitle: 'Unlocks advanced debugging, SSL bypass, internal logs',
        keywords: const [
          'developer',
          'dev',
          'ssl',
          'backend',
          'yt-dlp',
          'schedule',
          'backup',
          'reset'
        ],
        accentColor: red,
        builder: (ctx) => SwitchTile(
          accentColor: red,
          title: 'Enable Developer Mode',
          subtitle: 'Unlocks advanced debugging, SSL bypass, internal logs',
          value: settings.developerMode,
          onChanged: (val) => settings.toggleDeveloperMode(),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isRtl = L10n.isRtl(context);
    final isDark = settings.isDarkMode;
    final classicUi = settings.classicUi;
    final screenType = getScreenType(context);
    final isDesktop = screenType == ScreenType.desktop;

    if (_pageController.hasClients &&
        _pageController.page != null &&
        _pageController.page!.round() != _selectedCategoryIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _pageController.hasClients &&
            _pageController.page != null &&
            _pageController.page!.round() != _selectedCategoryIndex) {
          _pageController.jumpToPage(_selectedCategoryIndex);
        }
      });
    }

    final categories = [
      _CategoryMeta(
        id: 'appearance',
        title: isRtl ? 'المظهر' : 'Appearance',
        icon: Icons.palette_outlined,
        color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
      ),
      _CategoryMeta(
        id: 'downloads',
        title: isRtl ? 'التحميلات' : 'Downloads',
        icon: Icons.download_rounded,
        color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
      ),
      _CategoryMeta(
        id: 'network',
        title: isRtl ? 'الشبكة الأمان' : 'Network',
        icon: Icons.security_rounded,
        color: isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan,
      ),
      _CategoryMeta(
        id: 'notifications',
        title: isRtl ? 'الإشعارات' : 'Notifications',
        icon: Icons.notifications_active_outlined,
        color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
      ),
      _CategoryMeta(
        id: 'torrent',
        title: isRtl ? 'التورنت' : 'Torrent',
        icon: Icons.cloud_download_outlined,
        color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
      ),
      _CategoryMeta(
        id: 'power',
        title: isRtl ? 'الأداء والطاقة' : 'Power & Perf',
        icon: Icons.bolt_rounded,
        color: isDark ? AppTheme.neonOrange : AppTheme.lightNeonOrange,
      ),
      _CategoryMeta(
        id: 'advanced',
        title: isRtl ? 'متقدم' : 'Advanced',
        icon: Icons.tune_rounded,
        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
      ),
    ];

    final activeTabColor = categories[_selectedCategoryIndex].color;
    final filterAccentClr = activeTabColor;

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: classicUi
              ? (isDark
                  ? (settings.isAmoledMode
                      ? AppTheme.amoledBackground
                      : AppTheme.surface)
                  : AppTheme.lightSurface)
              : (settings.isAmoledMode
                  ? AppTheme.amoledBackground
                  : Colors.transparent),
          elevation: 0,
          flexibleSpace: (classicUi || settings.isAmoledMode)
              ? null
              : ClipRect(
                  child: DmxBackdropFilter(
                    sigmaX: 12,
                    sigmaY: 12,
                    child: Container(
                      color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                          .withValues(alpha: 0.5),
                    ),
                  ),
                ),
          title: Text(
            L10n.of(context, 'config_header'),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              letterSpacing: 2.0,
              fontSize: 14,
              fontFamily: 'Space Grotesk',
              color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          centerTitle: true,
          automaticallyImplyLeading: false,
          leading: isDesktop
              ? null
              : IconButton(
                  icon: Icon(
                    isRtl
                        ? Icons.arrow_forward_rounded
                        : Icons.arrow_back_rounded,
                    color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                  ),
                  onPressed: () {
                    triggerHaptic(settings);
                    context.read<DownloadProvider>().setActiveTabIndex(0);
                  },
                ),
        ),
        body: Directionality(
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: SafeArea(
            child: Column(
              children: [
                // Global Search Bar
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Theme(
                    data: Theme.of(context).copyWith(
                      primaryColor: filterAccentClr,
                      colorScheme: Theme.of(context).colorScheme.copyWith(
                            primary: filterAccentClr,
                          ),
                      textSelectionTheme: TextSelectionThemeData(
                        cursorColor: filterAccentClr,
                        selectionColor: filterAccentClr.withValues(alpha: 0.3),
                        selectionHandleColor: filterAccentClr,
                      ),
                    ),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      height: 44,
                      decoration: BoxDecoration(
                        color:
                            isDark ? AppTheme.surface : AppTheme.lightSurface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _searchFocusNode.hasFocus
                              ? filterAccentClr
                              : filterAccentClr.withValues(alpha: 0.35),
                          width: _searchFocusNode.hasFocus ? 1.8 : 1.0,
                        ),
                        boxShadow: _searchFocusNode.hasFocus
                            ? [
                                BoxShadow(
                                  color: filterAccentClr.withValues(alpha: 0.3),
                                  blurRadius: 10,
                                  spreadRadius: 1,
                                ),
                              ]
                            : null,
                      ),
                      child: TextField(
                        focusNode: _searchFocusNode,
                        controller: _searchController,
                        cursorColor: filterAccentClr,
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.textPrimary
                              : AppTheme.lightTextPrimary,
                          fontSize: 13,
                          fontFamily: 'Inter',
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            size: 18,
                            color: filterAccentClr,
                          ),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: Icon(Icons.clear_rounded,
                                      size: 16, color: filterAccentClr),
                                  onPressed: () {
                                    _searchController.clear();
                                  },
                                )
                              : null,
                          hintText: isRtl
                              ? 'ابحث في الإعدادات (مثلاً: proxy, dht, speed)...'
                              : 'Search all settings (e.g. proxy, dht, speed)...',
                          hintStyle: TextStyle(
                            color: isDark
                                ? AppTheme.textMuted
                                : AppTheme.lightTextMuted,
                            fontSize: 12,
                          ),
                          border: InputBorder.none,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ),
                ),

                // Search Overlay Mode vs Nav Mode
                if (_searchQuery.isNotEmpty)
                  Expanded(
                    child: _buildSearchResultsView(
                        context, settings, isDark, isRtl),
                  )
                else
                  Expanded(
                    child: (isDesktop || isTablet(context) || isLandscape(context))
                        ? Row(
                            children: [
                              // Side NavigationRail for Desktop / Tablet / Landscape
                              NavigationRail(
                                selectedIndex: _selectedCategoryIndex,
                                onDestinationSelected: _onCategorySelected,
                                backgroundColor: isDark
                                    ? AppTheme.surface.withValues(alpha: 0.7)
                                    : AppTheme.lightSurface
                                        .withValues(alpha: 0.7),
                                labelType: NavigationRailLabelType.all,
                                selectedIconTheme: IconThemeData(
                                  color:
                                      categories[_selectedCategoryIndex].color,
                                ),
                                selectedLabelTextStyle: TextStyle(
                                  color:
                                      categories[_selectedCategoryIndex].color,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'Space Grotesk',
                                  fontSize: 12,
                                ),
                                unselectedLabelTextStyle: TextStyle(
                                  color: isDark
                                      ? AppTheme.textMuted
                                      : AppTheme.lightTextMuted,
                                  fontFamily: 'Inter',
                                  fontSize: 11,
                                ),
                                destinations: categories
                                    .map(
                                      (cat) => NavigationRailDestination(
                                        icon: Icon(cat.icon, size: 20),
                                        selectedIcon: Icon(cat.icon, size: 22),
                                        label: Text(cat.title),
                                      ),
                                    )
                                    .toList(),
                              ),
                              const VerticalDivider(width: 1, thickness: 1),
                              Expanded(
                                child: PageView(
                                  controller: _pageController,
                                  physics: const NeverScrollableScrollPhysics(),
                                  children: const [
                                    AppearanceSettingsPage(),
                                    DownloadsSettingsPage(),
                                    NetworkSettingsPage(),
                                    NotificationsSettingsPage(),
                                    TorrentSettingsPage(),
                                    PowerSettingsPage(),
                                    AdvancedSettingsPage(),
                                  ],
                                ),
                              ),
                            ],
                          )
                        : Column(
                            children: [
                              // Phone/Tablet Horizontal Chip Strip
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                physics: const BouncingScrollPhysics(),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 4),
                                child: Row(
                                  children:
                                      List.generate(categories.length, (i) {
                                    final cat = categories[i];
                                    final selected =
                                        i == _selectedCategoryIndex;
                                    return Padding(
                                      padding:
                                          const EdgeInsets.only(right: 8.0),
                                      child: ChoiceChip(
                                        showCheckmark: false,
                                        avatar: Icon(
                                          cat.icon,
                                          size: 16,
                                          color: selected
                                              ? Colors.white
                                              : cat.color,
                                        ),
                                        label: Text(cat.title),
                                        labelStyle: TextStyle(
                                          color: selected
                                              ? Colors.white
                                              : cat.color,
                                          fontFamily: 'Space Grotesk',
                                          fontSize: 12,
                                          fontWeight: selected
                                              ? FontWeight.bold
                                              : FontWeight.w500,
                                        ),
                                        selected: selected,
                                        selectedColor: cat.color,
                                        backgroundColor: isDark
                                            ? AppTheme.surface
                                            : AppTheme.lightSurface,
                                        side: BorderSide(
                                          color: selected
                                              ? cat.color
                                              : cat.color
                                                  .withValues(alpha: 0.3),
                                          width: 1,
                                        ),
                                        onSelected: (_) =>
                                            _onCategorySelected(i),
                                      ),
                                    );
                                  }),
                                ),
                              ),
                              const Divider(height: 1, thickness: 1),
                              Expanded(
                                child: PageView(
                                  controller: _pageController,
                                  physics: const BouncingScrollPhysics(),
                                  onPageChanged: (idx) {
                                    setState(
                                        () => _selectedCategoryIndex = idx);
                                    context
                                        .read<SettingsProvider>()
                                        .setActiveSettingsTabIndex(idx);
                                  },
                                  children: const [
                                    AppearanceSettingsPage(),
                                    DownloadsSettingsPage(),
                                    NetworkSettingsPage(),
                                    NotificationsSettingsPage(),
                                    TorrentSettingsPage(),
                                    PowerSettingsPage(),
                                    AdvancedSettingsPage(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResultsView(
    BuildContext context,
    SettingsProvider settings,
    bool isDark,
    bool isRtl,
  ) {
    final results = _buildSearchIndex(context, settings, isDark, isRtl)
        .where((e) => e.matches(_searchQuery))
        .toList();

    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24.0),
        child: EmptyStateView(
          icon: Icons.search_off_rounded,
          title: 'No settings found for "$_searchQuery"',
          subtitle:
              'Try keywords like "proxy", "threads", "schedule", or "dht".',
        ),
      );
    }

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(16.0),
      itemCount: results.length,
      itemBuilder: (ctx, i) {
        final entry = results[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: () {
                  _searchController.clear();
                  _onCategorySelected(entry.categoryIndex);
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    children: [
                      Text(
                        entry.categoryTitle.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                          color: entry.accentColor,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(Icons.arrow_forward_ios_rounded,
                          size: 10, color: entry.accentColor),
                    ],
                  ),
                ),
              ),
              entry.builder(ctx),
            ],
          ),
        );
      },
    );
  }
}

class _CategoryMeta {
  final String id;
  final String title;
  final IconData icon;
  final Color color;

  const _CategoryMeta({
    required this.id,
    required this.title,
    required this.icon,
    required this.color,
  });
}
