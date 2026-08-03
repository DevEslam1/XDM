import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:logging/logging.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/constants.dart';
import '../../../core/services/xdm_backend_client.dart';
import '../../../core/services/update_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/dmx_app_icon.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../browser/services/ad_blocker_service.dart';
import '../../browser/services/custom_adblock_store.dart';
import '../../../core/services/doh_resolver.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/models/download_task.dart';
import '../provider/settings_provider.dart';
import '../widgets/update_dialogs.dart';

// FIX(15): Model for settings search index entries
class _SettingSearchEntry {
  final String sectionTitle;
  final String settingTitle;
  final String? subtitle;
  final List<String> keywords;
  final Widget Function(BuildContext context) builder;
  final Color accentColor;

  const _SettingSearchEntry({
    required this.sectionTitle,
    required this.settingTitle,
    this.subtitle,
    this.keywords = const [],
    required this.builder,
    required this.accentColor,
  });

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    if (sectionTitle.toLowerCase().contains(q)) return true;
    if (settingTitle.toLowerCase().contains(q)) return true;
    if (subtitle?.toLowerCase().contains(q) ?? false) return true;
    return keywords.any((k) => k.toLowerCase().contains(q));
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with HapticHelper, TickerProviderStateMixin {
  bool _isUpdatingAdBlock = false;
  late final TextEditingController _uaController;
  late final TextEditingController _proxyHostController;
  late final TextEditingController _proxyPortController;
  late final TextEditingController _proxyUsernameController;
  late final TextEditingController _proxyPasswordController;
  late final TextEditingController _backendUrlController;
  late final TextEditingController _settingsSearchController;
  String _settingsSearchQuery = '';
  final Map<String, bool> _expandedSections = {};
  late AnimationController _reveal;

  @override
  void initState() {
    super.initState();
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    _uaController = TextEditingController(text: settings.customUserAgent);
    _proxyHostController = TextEditingController(text: settings.proxyHost);
    _proxyPortController = TextEditingController(
      text: settings.proxyPort.toString(),
    );
    _proxyUsernameController = TextEditingController(
      text: settings.proxyUsername,
    );
    _proxyPasswordController = TextEditingController(
      text: settings.proxyPassword,
    );
    _backendUrlController = TextEditingController(text: settings.backendUrl);
    _settingsSearchController = TextEditingController();
    _settingsSearchController.addListener(() {
      if (mounted) {
        setState(() {
          _settingsSearchQuery =
              _settingsSearchController.text.trim().toLowerCase();
        });
      }
    });
    _reveal = AnimationController(vsync: this, duration: AppTheme.motionReveal)
      ..forward();
  }

  List<_SettingSearchEntry> _buildSearchIndex(
    BuildContext context,
    SettingsProvider settings,
  ) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

    return <_SettingSearchEntry>[
      // --- Section 01: Engine ---
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_engine_status'),
        settingTitle: L10n.of(context, 'settings_auto_resume'),
        subtitle: L10n.of(context, 'settings_auto_resume_sub'),
        keywords: ['resume', 'auto', 'start', 'download'],
        accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        builder: (ctx) => _SwitchTile(
          accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          title: L10n.of(ctx, 'settings_auto_resume'),
          subtitle: L10n.of(ctx, 'settings_auto_resume_sub'),
          value: settings.autoStart,
          onChanged: (val) {
            settings.setAutoStart(val);
            triggerHaptic(settings);
          },
        ),
      ),
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_engine_status'),
        settingTitle: L10n.of(context, 'settings_max_channels'),
        subtitle: L10n.of(context, 'settings_max_channels_sub'),
        keywords: ['channels', 'parallel', 'max', 'concurrent'],
        accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        builder: (ctx) => _DropdownTile<int>(
          accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          title: L10n.of(ctx, 'settings_max_channels'),
          subtitle: settings.batterySaverMode
              ? (isRtl
                  ? 'محدود بـ ${settings.effectiveMaxDownloads} بسبب موفر البطارية'
                  : 'Limited to ${settings.effectiveMaxDownloads} by Battery Saver')
              : L10n.of(ctx, 'settings_max_channels_sub'),
          value: settings.maxDownloads,
          items: const [1, 2, 3, 5, 8],
          onChanged: settings.batterySaverMode
              ? null
              : (val) {
                  if (val != null) {
                    settings.setMaxDownloads(val);
                    triggerHaptic(settings);
                  }
                },
        ),
      ),
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_engine_status'),
        settingTitle: L10n.of(context, 'settings_default_threads'),
        subtitle: L10n.of(context, 'settings_default_threads_sub'),
        keywords: ['threads', 'connection', 'per', 'download'],
        accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        builder: (ctx) => _DropdownTile<int>(
          accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          title: L10n.of(ctx, 'settings_default_threads'),
          subtitle: settings.batterySaverMode
              ? (isRtl
                  ? 'محدود بـ ${settings.effectiveDefaultThreadCount} بسبب موفر البطارية'
                  : 'Limited to ${settings.effectiveDefaultThreadCount} by Battery Saver')
              : L10n.of(ctx, 'settings_default_threads_sub'),
          value: settings.defaultThreadCount,
          items: kAvailableThreadOptions,
          onChanged: settings.batterySaverMode
              ? null
              : (val) {
                  if (val != null) {
                    settings.setDefaultThreadCount(val);
                    triggerHaptic(settings);
                  }
                },
        ),
      ),
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_engine_status'),
        settingTitle: L10n.of(context, 'settings_lang'),
        subtitle: L10n.of(context, 'settings_lang_sub'),
        keywords: ['language', 'english', 'arabic', 'ar', 'en'],
        accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        builder: (ctx) => _DropdownTile<String>(
          accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          title: L10n.of(ctx, 'settings_lang'),
          subtitle: L10n.of(ctx, 'settings_lang_sub'),
          value: settings.languageCode,
          items: const ['en', 'ar'],
          itemLabels: {'en': 'ENGLISH', 'ar': 'العربية'},
          onChanged: (val) {
            if (val != null) {
              settings.setLanguageCode(val);
              triggerHaptic(settings);
            }
          },
        ),
      ),
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_engine_status'),
        settingTitle:
            isRtl ? 'مجلد التحميل الافتراضي' : 'Default Download Folder',
        subtitle: settings.customDownloadPath?.isNotEmpty == true
            ? settings.customDownloadPath!
            : (isRtl ? 'تلقائي (Downloads/XDM)' : 'Default (Downloads/XDM)'),
        keywords: ['folder', 'path', 'directory', 'storage', 'save'],
        accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        builder: (ctx) => _PathPickerTile(
          accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          title: isRtl ? 'مجلد التحميل الافتراضي' : 'Default Download Folder',
          subtitle: settings.customDownloadPath?.isNotEmpty == true
              ? settings.customDownloadPath!
              : (isRtl ? 'تلقائي (Downloads/XDM)' : 'Default (Downloads/XDM)'),
          onTap: () async {
            triggerHaptic(settings);
            final path = await FilePicker.getDirectoryPath();
            if (path != null) {
              await settings.setCustomDownloadPath(path);
            }
          },
          onClear: settings.customDownloadPath?.isNotEmpty == true
              ? () async {
                  triggerHaptic(settings);
                  await settings.setCustomDownloadPath(null);
                }
              : null,
        ),
      ),

      // --- Section 02: Bandwidth ---
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_bandwidth'),
        settingTitle: L10n.of(context, 'settings_speed_limit'),
        subtitle: L10n.of(context, 'settings_limit_to'),
        keywords: ['speed', 'limit', 'bandwidth', 'rate', 'slow'],
        accentColor: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
        builder: (ctx) => _SliderTile(
          accentColor: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          title: L10n.of(ctx, 'settings_speed_limit'),
          valueLabel: settings.speedLimitMb == 0.0
              ? L10n.of(ctx, 'settings_unlimited')
              : '${settings.speedLimitMb.toInt()} MB/s',
          subtitle: L10n.of(ctx, 'settings_limit_to'),
          value: settings.speedLimitMb,
          min: 0.0,
          max: 100.0,
          divisions: 10,
          onChanged: (val) => settings.setSpeedLimit(val),
          onChangeEnd: (val) => triggerHaptic(settings),
        ),
      ),
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_bandwidth'),
        settingTitle: L10n.of(context, 'settings_wifi_only'),
        subtitle: L10n.of(context, 'settings_wifi_only_sub'),
        keywords: ['wifi', 'mobile', 'data', 'cellular', 'network'],
        accentColor: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
        builder: (ctx) => _SwitchTile(
          accentColor: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          title: L10n.of(ctx, 'settings_wifi_only'),
          subtitle: L10n.of(ctx, 'settings_wifi_only_sub'),
          value: settings.wifiOnly,
          onChanged: (val) {
            settings.setWifiOnly(val);
            triggerHaptic(settings);
          },
        ),
      ),
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_bandwidth'),
        settingTitle: isRtl ? 'تفعيل مشاركة التورنت (Seeding)' : 'Torrent Seeding',
        subtitle: isRtl
            ? 'مشاركة أجزاء الملفات بعد اكتمال التحميل'
            : 'Share files back to peers after download completes',
        keywords: ['torrent', 'seed', 'upload', 'share', 'ratio'],
        accentColor: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
        builder: (ctx) => _SwitchTile(
          accentColor: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          title: isRtl ? 'تفعيل مشاركة التورنت (Seeding)' : 'Torrent Seeding',
          subtitle: isRtl
              ? 'مشاركة أجزاء الملفات بعد اكتمال التحميل'
              : 'Share files back to peers after download completes',
          value: settings.globalTorrentSeeding,
          onChanged: (val) {
            settings.setGlobalTorrentSeeding(val);
            triggerHaptic(settings);
          },
        ),
      ),
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_bandwidth'),
        settingTitle: isRtl ? 'تقييد سرعة المشاركة' : 'Limit Seeding Speed',
        subtitle: isRtl
            ? 'تحديد حد أقصى لسرعة الرفع'
            : 'Set a maximum limit for upload speed',
        keywords: ['torrent', 'seed', 'upload', 'speed', 'limit'],
        accentColor: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
        builder: (ctx) => _SwitchTile(
          accentColor: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          title: isRtl ? 'تقييد سرعة المشاركة' : 'Limit Seeding Speed',
          subtitle: isRtl
              ? 'تحديد حد أقصى لسرعة الرفع'
              : 'Set a maximum limit for upload speed',
          value: settings.globalTorrentSeedingLimited,
          onChanged: (val) {
            settings.setGlobalTorrentSeedingLimited(val);
            triggerHaptic(settings);
          },
        ),
      ),
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_bandwidth'),
        settingTitle: isRtl
            ? 'أقصى عدد ملفات متزامنة لكل تورنت'
            : 'Max Concurrent Files Per Torrent',
        subtitle: isRtl
            ? 'حد عدد الملفات التي يتم تحميلها بالتوازي في التورنت الواحد (0 = الكل)'
            : 'Limit files downloading simultaneously per torrent (0 = all)',
        keywords: ['torrent', 'files', 'concurrent', 'parallel'],
        accentColor: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
        builder: (ctx) => _DropdownTile<int>(
          accentColor: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          title: isRtl
              ? 'أقصى عدد ملفات متزامنة لكل تورنت'
              : 'Max Concurrent Files Per Torrent',
          subtitle: isRtl
              ? 'حد عدد الملفات التي يتم تحميلها بالتوازي في التورنت الواحد (0 = الكل)'
              : 'Limit files downloading simultaneously per torrent (0 = all)',
          value: settings.maxConcurrentFilesPerTorrent,
          items: const [0, 1, 2, 3, 5, 10],
          itemLabels: {
            0: isRtl ? 'الكل (غير محدود)' : 'All (Unlimited)',
            1: '1',
            2: '2',
            3: '3',
            5: '5',
            10: '10',
          },
          onChanged: (val) {
            if (val != null) {
              settings.setMaxConcurrentFilesPerTorrent(val);
              triggerHaptic(settings);
            }
          },
        ),
      ),

      // --- Section 03: Cockpit ---
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_cockpit'),
        settingTitle: isRtl ? 'سمة المظهر' : 'THEME MODE',
        subtitle: isRtl ? 'اختر سمة مظهر التطبيق' : 'Select application theme mode',
        keywords: ['theme', 'dark', 'light', 'appearance', 'mode'],
        accentColor: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
        builder: (ctx) => _DropdownTile<String>(
          accentColor: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
          title: isRtl ? 'سمة المظهر' : 'THEME MODE',
          subtitle: isRtl ? 'اختر سمة مظهر التطبيق' : 'Select application theme mode',
          value: settings.themeMode,
          items: const ['light', 'dark', 'system'],
          itemLabels: {
            'light': isRtl ? 'فاتح' : 'LIGHT',
            'dark': isRtl ? 'داكن' : 'DARK',
            'system': isRtl ? 'تلقائي' : 'SYSTEM DEFAULT',
          },
          onChanged: (val) {
            if (val != null) {
              settings.setThemeMode(val);
              triggerHaptic(settings);
            }
          },
        ),
      ),
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_cockpit'),
        settingTitle: L10n.of(context, 'settings_classic_ui'),
        subtitle: settings.batterySaverMode
            ? (isRtl ? 'مفعل بواسطة موفر البطارية' : 'Forced ON by Battery Saver')
            : L10n.of(context, 'settings_classic_ui_sub'),
        keywords: ['ui', 'classic', 'modern', 'style'],
        accentColor: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
        builder: (ctx) => _SwitchTile(
          accentColor: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
          title: L10n.of(ctx, 'settings_classic_ui'),
          subtitle: settings.batterySaverMode
              ? (isRtl
                  ? 'مفعل بواسطة موفر البطارية'
                  : 'Forced ON by Battery Saver')
              : L10n.of(ctx, 'settings_classic_ui_sub'),
          value: settings.classicUi,
          onChanged: settings.batterySaverMode
              ? null
              : (val) {
                  settings.setClassicUi(val);
                  triggerHaptic(settings);
                },
        ),
      ),
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_cockpit'),
        settingTitle: L10n.of(context, 'settings_glow'),
        subtitle: L10n.of(context, 'settings_glow_sub'),
        keywords: ['glow', 'neon', 'effect', 'visual'],
        accentColor: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
        builder: (ctx) => _SwitchTile(
          accentColor: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
          title: L10n.of(ctx, 'settings_glow'),
          subtitle: L10n.of(ctx, 'settings_glow_sub'),
          value: settings.enableGlow,
          onChanged: (val) {
            settings.setEnableGlow(val);
            triggerHaptic(settings);
          },
        ),
      ),
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_cockpit'),
        settingTitle: L10n.of(context, 'settings_grid'),
        subtitle: L10n.of(context, 'settings_grid_sub'),
        keywords: ['grid', 'background', 'opacity', 'visual'],
        accentColor: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
        builder: (ctx) => _SliderTile(
          accentColor: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
          title: L10n.of(ctx, 'settings_grid'),
          valueLabel: '${settings.gridOpacity.toInt()}%',
          subtitle: L10n.of(ctx, 'settings_grid_sub'),
          value: settings.gridOpacity,
          min: 0.0,
          max: 40.0,
          divisions: 8,
          onChanged: (val) => settings.setGridOpacity(val),
          onChangeEnd: (val) => triggerHaptic(settings),
        ),
      ),

      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_alerters'),
        settingTitle: isRtl ? 'الإشعارات العامة' : 'GLOBAL NOTIFICATIONS',
        subtitle: isRtl
            ? 'تفعيل أو تعطيل جميع إشعارات التطبيق'
            : 'Enable or disable all app notifications',
        keywords: ['notification', 'alert', 'push', 'message'],
        accentColor: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
        builder: (ctx) => _SwitchTile(
          accentColor: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
          title: isRtl ? 'الإشعارات العامة' : 'GLOBAL NOTIFICATIONS',
          subtitle: isRtl
              ? 'تفعيل أو تعطيل جميع إشعارات التطبيق'
              : 'Enable or disable all app notifications',
          value: settings.notificationsEnabled,
          onChanged: (val) {
            settings.setNotificationsEnabled(val);
            triggerHaptic(settings);
          },
        ),
      ),
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_alerters'),
        settingTitle: L10n.of(context, 'settings_chime'),
        subtitle: L10n.of(context, 'settings_chime_sub'),
        keywords: ['sound', 'chime', 'notification', 'audio', 'alert'],
        accentColor: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
        builder: (ctx) => _SwitchTile(
          accentColor: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
          title: L10n.of(ctx, 'settings_chime'),
          subtitle: L10n.of(ctx, 'settings_chime_sub'),
          value: settings.soundNotification,
          onChanged: (val) {
            settings.setSoundNotification(val);
            triggerHaptic(settings);
          },
        ),
      ),
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_alerters'),
        settingTitle: L10n.of(context, 'settings_auto_retry'),
        subtitle: L10n.of(context, 'settings_auto_retry_sub'),
        keywords: ['retry', 'fail', 'auto', 'resume', 'network'],
        accentColor: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
        builder: (ctx) => _SwitchTile(
          accentColor: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
          title: L10n.of(ctx, 'settings_auto_retry'),
          subtitle: L10n.of(ctx, 'settings_auto_retry_sub'),
          value: settings.autoRetryEnabled,
          onChanged: (val) {
            settings.setAutoRetryEnabled(val);
            triggerHaptic(settings);
          },
        ),
      ),

      // --- Section 05: Telemetry ---
      _SettingSearchEntry(
        sectionTitle: isRtl ? 'مراقب الأداء' : 'TELEMETRY',
        settingTitle: isRtl ? 'وضع توفير البطارية الأقصى' : 'Battery Saver Mode',
        subtitle: isRtl
            ? 'يقيد قنوات الاتصال إلى ٢، والتحميلات المتزامنة إلى ١'
            : 'Limits threads to 2, downloads to 1',
        keywords: ['battery', 'saver', 'power', 'performance', 'efficiency'],
        accentColor: isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan,
        builder: (ctx) => _SwitchTile(
          accentColor: isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan,
          title: isRtl ? 'وضع توفير البطارية الأقصى' : 'Battery Saver Mode',
          subtitle: isRtl
              ? 'يقيد قنوات الاتصال إلى ٢، والتحميلات المتزامنة إلى ١'
              : 'Limits threads to 2, downloads to 1',
          value: settings.batterySaverMode,
          onChanged: (val) {
            settings.setBatterySaverMode(val);
            triggerHaptic(settings);
          },
        ),
      ),

      // --- Section 08c: DNS ---
      _SettingSearchEntry(
        sectionTitle: isRtl ? 'إعدادات DNS المخصصة (DoH)' : 'CUSTOM DNS (DoH) SETTINGS',
        settingTitle: isRtl ? 'تفعيل DNS المخصص (DoH)' : 'ENABLE CUSTOM DNS (DoH)',
        subtitle: isRtl
            ? 'تشفير طلبات DNS وتجاوز مزود الخدمة المحلي'
            : 'Encrypt DNS queries and bypass local ISP resolvers',
        keywords: ['dns', 'doh', 'https', 'secure', 'privacy', 'adguard', 'cloudflare', 'google'],
        accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        builder: (ctx) => _SwitchTile(
          accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          title: isRtl ? 'تفعيل DNS المخصص (DoH)' : 'ENABLE CUSTOM DNS (DoH)',
          subtitle: isRtl
              ? 'تشفير طلبات DNS وتجاوز مزود الخدمة المحلي'
              : 'Encrypt DNS queries and bypass local ISP resolvers',
          value: settings.dnsEnabled,
          onChanged: (val) => settings.setDnsEnabled(val),
        ),
      ),

      // --- Section 09: Accessibility ---
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_accessibility_title'),
        settingTitle: isRtl ? 'تقليل المؤثرات البصرية' : 'REDUCE MOTION & VISUALS',
        subtitle: isRtl
            ? 'إيقاف تأثيرات التوهج والضبابية لتحسين سهولة القراءة والأداء'
            : 'Disable animation, glow, and blur effects to improve readability and performance',
        keywords: ['motion', 'visual', 'animation', 'glow', 'blur', 'performance', 'accessibility'],
        accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        builder: (ctx) => _SwitchTile(
          accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          title: isRtl ? 'تقليل المؤثرات البصرية' : 'REDUCE MOTION & VISUALS',
          subtitle: isRtl
              ? 'إيقاف تأثيرات التوهج والضبابية لتحسين سهولة القراءة والأداء'
              : 'Disable animation, glow, and blur effects to improve readability and performance',
          value: settings.reduceVisuals,
          onChanged: (val) {
            settings.setReduceVisuals(val);
            triggerHaptic(settings);
          },
        ),
      ),
      _SettingSearchEntry(
        sectionTitle: L10n.of(context, 'settings_accessibility_title'),
        settingTitle: L10n.of(context, 'settings_text_scaling'),
        subtitle: L10n.of(context, 'settings_text_scaling_sub'),
        keywords: ['font', 'size', 'text', 'scaling', 'large', 'small'],
        accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        builder: (ctx) => _SliderTile(
          accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          title: L10n.of(ctx, 'settings_text_scaling'),
          valueLabel: '${(settings.textScaleFactor * 100).toInt()}%',
          subtitle: L10n.of(ctx, 'settings_text_scaling_sub'),
          value: settings.textScaleFactor,
          min: 0.8,
          max: 2.0,
          divisions: 12,
          onChanged: (val) => settings.setTextScaleFactor(val),
          onChangeEnd: (val) => triggerHaptic(settings),
        ),
      ),
    ];
  }

  Timer? _backendUrlDebounce;

  void _saveBackendUrl(String val, SettingsProvider settings) {
    final trimmed = val.trim();
    if (trimmed.isEmpty ||
        trimmed.startsWith('http://') ||
        trimmed.startsWith('https://')) {
      settings.setBackendUrl(trimmed);
    }
  }

  void _onBackendUrlChanged(String val, SettingsProvider settings) {
    _backendUrlDebounce?.cancel();
    _backendUrlDebounce = Timer(const Duration(milliseconds: 600), () {
      _saveBackendUrl(val, settings);
    });
  }

  @override
  void dispose() {
    _backendUrlDebounce?.cancel();
    _uaController.dispose();
    _proxyHostController.dispose();
    _proxyPortController.dispose();
    _proxyUsernameController.dispose();
    _proxyPasswordController.dispose();
    _backendUrlController.dispose();
    _settingsSearchController.dispose();
    _reveal.dispose();
    super.dispose();
  }

  bool _sectionMatches(String title, List<String> keywords) {
    if (_settingsSearchQuery.isEmpty) return true;
    final q = _settingsSearchQuery.toLowerCase();
    return title.toLowerCase().contains(q) ||
        keywords.any((k) => k.toLowerCase().contains(q));
  }

  Widget _stagger(double start, Widget child) {
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: _reveal,
        curve: Interval(
          start,
          (start + 0.4).clamp(0.0, 1.0),
          curve: AppTheme.motionCurve,
        ),
      ),
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero)
            .animate(
          CurvedAnimation(
            parent: _reveal,
            curve: Interval(
              start,
              (start + 0.4).clamp(0.0, 1.0),
              curve: AppTheme.motionCurve,
            ),
          ),
        ),
        child: child,
      ),
    );
  }

  void _maybeConfirmBypassSSL(
    BuildContext context,
    SettingsProvider settings,
  ) {
    if (!settings.pendingBypassSSLConfirmation) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(L10n.of(dialogContext, 'bypass_ssl_dialog_title')),
        content: Text(L10n.of(dialogContext, 'bypass_ssl_dialog_body')),
        actions: [
          TextButton(
            onPressed: () {
              settings.setBypassSSL(false);
              Navigator.pop(dialogContext);
            },
            child: Text(L10n.of(dialogContext, 'cancel_btn')),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              settings.confirmBypassSSL();
              Navigator.pop(dialogContext);
            },
            child: Text(L10n.of(dialogContext, 'bypass_ssl_dialog_confirm')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isRtl = L10n.isRtl(context);
    final isDark = settings.isDarkMode;
    final classicUi = settings.classicUi;

    // FIX(15): Build search index and filter results
    final searchResults = <_SettingSearchEntry>[];
    if (_settingsSearchQuery.isNotEmpty) {
      final index = _buildSearchIndex(context, settings);
      for (final entry in index) {
        if (entry.matches(_settingsSearchQuery)) {
          searchResults.add(entry);
        }
      }
    }

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: classicUi
              ? (isDark ? AppTheme.surface : AppTheme.lightSurface)
              : Colors.transparent,
          elevation: 0,
          shape: classicUi
              ? Border(
                  bottom: BorderSide(
                    color: isDark ? AppTheme.border : AppTheme.lightBorder,
                    width: 1.0,
                  ),
                )
              : null,
          flexibleSpace: classicUi
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
        ),
        body: Directionality(
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _stagger(0.0, _SystemHeader(settings: settings)),
                  const SizedBox(height: 12),
                  _stagger(
                    0.04,
                    Container(
                      decoration: BoxDecoration(
                        color:
                            isDark ? AppTheme.surface : AppTheme.lightSurface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color:
                              isDark ? AppTheme.border : AppTheme.lightBorder,
                          width: 1.0,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 2),
                      child: Row(
                        children: [
                          Icon(
                            Icons.search_rounded,
                            color: isDark
                                ? AppTheme.neonBlue
                                : AppTheme.lightNeonBlue,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _settingsSearchController,
                              style: TextStyle(
                                color: isDark
                                    ? AppTheme.textPrimary
                                    : AppTheme.lightTextPrimary,
                                fontFamily: 'Inter',
                                fontSize: 13,
                              ),
                              decoration: InputDecoration(
                                hintText:
                                    L10n.of(context, 'search_settings_hint'),
                                hintStyle: TextStyle(
                                  color: isDark
                                      ? AppTheme.textMuted
                                      : AppTheme.lightTextMuted,
                                  fontSize: 13,
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding:
                                    const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                          if (_settingsSearchQuery.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 18),
                              color: isDark
                                  ? AppTheme.textSecondary
                                  : AppTheme.lightTextSecondary,
                              onPressed: () {
                                _settingsSearchController.clear();
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_settingsSearchQuery.isNotEmpty) ...[
                    // FIX(15): Render search results
                    if (searchResults.isEmpty)
                      _stagger(
                        0.08,
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox(height: 40),
                            Icon(
                              Icons.search_off_rounded,
                              size: 48,
                              color: isDark
                                  ? AppTheme.textMuted
                                  : AppTheme.lightTextMuted,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              isRtl
                                  ? 'لم يتم العثور على إعدادات تطابق "$_settingsSearchQuery"'
                                  : 'No settings found for "$_settingsSearchQuery"',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: isDark
                                    ? AppTheme.textSecondary
                                    : AppTheme.lightTextSecondary,
                              ),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          isRtl
                              ? 'تم العثور على ${searchResults.length} نتيجة لـ "$_settingsSearchQuery"'
                              : 'Found ${searchResults.length} results for "$_settingsSearchQuery"',
                          style: TextStyle(
                            color: isDark
                                ? AppTheme.textMuted
                                : AppTheme.lightTextMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      ...searchResults.map((entry) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsetsDirectional.only(
                                      start: 16, bottom: 4),
                                  child: Text(
                                    entry.sectionTitle.toUpperCase(),
                                    style: TextStyle(
                                      color: entry.accentColor,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                ),
                                entry.builder(context),
                              ],
                            ),
                          )),
                    ],
                  ] else ...[
                    // Render normal sections
                    if (_sectionMatches(
                        L10n.of(context, 'settings_engine_status'),
                        ['auto resume', 'max channels', 'speed limit']))
                      _stagger(
                        0.08,
                        _ConsoleSection(
                          index: '01',
                          title: L10n.of(context, 'settings_engine_status'),
                          accentColor: isDark
                              ? AppTheme.neonBlue
                              : AppTheme.lightNeonBlue,
                          isDark: isDark,
                          isExpanded: _expandedSections['engine'] ?? true,
                          onToggle: () {
                            triggerHaptic(settings);
                            setState(() {
                              _expandedSections['engine'] =
                                  !(_expandedSections['engine'] ?? true);
                            });
                          },
                          children: [
                            _SwitchTile(
                              accentColor: isDark
                                  ? AppTheme.neonBlue
                                  : AppTheme.lightNeonBlue,
                              title: L10n.of(context, 'settings_auto_resume'),
                              subtitle: L10n.of(
                                context,
                                'settings_auto_resume_sub',
                              ),
                              value: settings.autoStart,
                              onChanged: (val) {
                                settings.setAutoStart(val);
                                triggerHaptic(settings);
                              },
                            ),
                            _Divider(isDark: isDark),
                            _DropdownTile<int>(
                              accentColor: isDark
                                  ? AppTheme.neonBlue
                                  : AppTheme.lightNeonBlue,
                              title: L10n.of(context, 'settings_max_channels'),
                              subtitle: settings.batterySaverMode
                                  ? (isRtl
                                      ? 'محدود بـ ${settings.effectiveMaxDownloads} بسبب موفر البطارية'
                                      : 'Limited to ${settings.effectiveMaxDownloads} by Battery Saver')
                                  : L10n.of(
                                      context, 'settings_max_channels_sub'),
                              value: settings.maxDownloads,
                              items: const [1, 2, 3, 5, 8],
                              onChanged: settings.batterySaverMode
                                  ? null
                                  : (val) {
                                      if (val != null) {
                                        settings.setMaxDownloads(val);
                                        triggerHaptic(settings);
                                      }
                                    },
                            ),
                            _Divider(isDark: isDark),
                            _DropdownTile<int>(
                              accentColor: isDark
                                  ? AppTheme.neonBlue
                                  : AppTheme.lightNeonBlue,
                              title:
                                  L10n.of(context, 'settings_default_threads'),
                              subtitle: settings.batterySaverMode
                                  ? (isRtl
                                      ? 'محدود بـ ${settings.effectiveDefaultThreadCount} بسبب موفر البطارية'
                                      : 'Limited to ${settings.effectiveDefaultThreadCount} by Battery Saver')
                                  : L10n.of(
                                      context,
                                      'settings_default_threads_sub',
                                    ),
                              value: settings.defaultThreadCount,
                              items: kAvailableThreadOptions,
                              onChanged: settings.batterySaverMode
                                  ? null
                                  : (val) {
                                      if (val != null) {
                                        settings.setDefaultThreadCount(val);
                                        triggerHaptic(settings);
                                      }
                                    },
                            ),
                            _Divider(isDark: isDark),
                            _DropdownTile<String>(
                              accentColor: isDark
                                  ? AppTheme.neonBlue
                                  : AppTheme.lightNeonBlue,
                              title: L10n.of(context, 'settings_lang'),
                              subtitle: L10n.of(context, 'settings_lang_sub'),
                              value: settings.languageCode,
                              items: const ['en', 'ar'],
                              itemLabels: {'en': 'ENGLISH', 'ar': 'العربية'},
                              onChanged: (val) {
                                if (val != null) {
                                  settings.setLanguageCode(val);
                                  triggerHaptic(settings);
                                }
                              },
                            ),
                            _Divider(isDark: isDark),
                            _PathPickerTile(
                              accentColor: isDark
                                  ? AppTheme.neonBlue
                                  : AppTheme.lightNeonBlue,
                              title: isRtl
                                  ? 'مجلد التحميل الافتراضي'
                                  : 'Default Download Folder',
                              subtitle: settings
                                          .customDownloadPath?.isNotEmpty ==
                                      true
                                  ? settings.customDownloadPath!
                                  : (isRtl
                                      ? 'تلقائي (Downloads/XDM)'
                                      : 'Default (Downloads/XDM)'),
                              onTap: () async {
                                triggerHaptic(settings);
                                final path =
                                    await FilePicker.getDirectoryPath();
                                if (path != null) {
                                  await settings.setCustomDownloadPath(path);
                                }
                              },
                              onClear:
                                  settings.customDownloadPath?.isNotEmpty ==
                                          true
                                      ? () async {
                                          triggerHaptic(settings);
                                          await settings
                                              .setCustomDownloadPath(null);
                                        }
                                      : null,
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 14),
                    _stagger(
                      0.16,
                      _ConsoleSection(
                        index: '02',
                        title: L10n.of(context, 'settings_bandwidth'),
                        accentColor: isDark
                            ? AppTheme.neonGreen
                            : AppTheme.lightNeonGreen,
                        isDark: isDark,
                        isExpanded: _expandedSections['bandwidth'] ?? false,
                        onToggle: () {
                          triggerHaptic(settings);
                          setState(() {
                            _expandedSections['bandwidth'] =
                                !(_expandedSections['bandwidth'] ?? false);
                          });
                        },
                        children: [
                          _SliderTile(
                            accentColor: isDark
                                ? AppTheme.neonGreen
                                : AppTheme.lightNeonGreen,
                            title: L10n.of(context, 'settings_speed_limit'),
                            valueLabel: settings.speedLimitMb == 0.0
                                ? L10n.of(context, 'settings_unlimited')
                                : '${settings.speedLimitMb.toInt()} MB/s',
                            subtitle: L10n.of(context, 'settings_limit_to'),
                            value: settings.speedLimitMb,
                            min: 0.0,
                            max: 100.0,
                            divisions: 10,
                            onChanged: (val) => settings.setSpeedLimit(val),
                            onChangeEnd: (val) => triggerHaptic(settings),
                          ),
                          _Divider(isDark: isDark),
                          _SwitchTile(
                            accentColor: isDark
                                ? AppTheme.neonGreen
                                : AppTheme.lightNeonGreen,
                            title: L10n.of(context, 'settings_wifi_only'),
                            subtitle:
                                L10n.of(context, 'settings_wifi_only_sub'),
                            value: settings.wifiOnly,
                            onChanged: (val) {
                              settings.setWifiOnly(val);
                              triggerHaptic(settings);
                            },
                          ),
                          _Divider(isDark: isDark),
                          _SwitchTile(
                            accentColor: isDark
                                ? AppTheme.neonGreen
                                : AppTheme.lightNeonGreen,
                            title: L10n.isRtl(context)
                                ? 'تفعيل مشاركة التورنت (Seeding)'
                                : 'Torrent Seeding',
                            subtitle: L10n.isRtl(context)
                                ? 'مشاركة أجزاء الملفات بعد اكتمال التحميل'
                                : 'Share files back to peers after download completes',
                            value: settings.globalTorrentSeeding,
                            onChanged: (val) {
                              settings.setGlobalTorrentSeeding(val);
                              triggerHaptic(settings);
                            },
                          ),
                          if (settings.globalTorrentSeeding) ...[
                            _Divider(isDark: isDark),
                            _SwitchTile(
                              accentColor: isDark
                                  ? AppTheme.neonGreen
                                  : AppTheme.lightNeonGreen,
                              title: L10n.isRtl(context)
                                  ? 'تقييد سرعة المشاركة'
                                  : 'Limit Seeding Speed',
                              subtitle: L10n.isRtl(context)
                                  ? 'تحديد حد أقصى لسرعة الرفع'
                                  : 'Set a maximum limit for upload speed',
                              value: settings.globalTorrentSeedingLimited,
                              onChanged: (val) {
                                settings.setGlobalTorrentSeedingLimited(val);
                                triggerHaptic(settings);
                              },
                            ),
                            if (settings.globalTorrentSeedingLimited) ...[
                              _Divider(isDark: isDark),
                              _SliderTile(
                                accentColor: isDark
                                    ? AppTheme.neonGreen
                                    : AppTheme.lightNeonGreen,
                                title: L10n.isRtl(context)
                                    ? 'سرعة الرفع القصوى'
                                    : 'Maximum Upload Speed',
                                subtitle:
                                    '${settings.globalTorrentSeedingLimitKbps} kbps',
                                value: settings.globalTorrentSeedingLimitKbps
                                    .toDouble(),
                                min: 100.0,
                                max: 10000.0,
                                divisions: 99,
                                onChanged: (val) =>
                                    settings.setGlobalTorrentSeedingLimitKbps(
                                  val.round(),
                                ),
                                onChangeEnd: (val) => triggerHaptic(settings),
                              ),
                            ],
                          ],
                          _Divider(isDark: isDark),
                          _SwitchTile(
                            accentColor: isDark
                                ? AppTheme.neonGreen
                                : AppTheme.lightNeonGreen,
                            title: L10n.of(context, 'settings_auto_retry'),
                            subtitle:
                                L10n.of(context, 'settings_auto_retry_sub'),
                            value: settings.autoRetryEnabled,
                            onChanged: (val) {
                              settings.setAutoRetryEnabled(val);
                              triggerHaptic(settings);
                            },
                          ),
                          // FIX(6): Max concurrent files per torrent dropdown
                          _Divider(isDark: isDark),
                          _DropdownTile<int>(
                            accentColor: isDark
                                ? AppTheme.neonGreen
                                : AppTheme.lightNeonGreen,
                            title: L10n.isRtl(context)
                                ? 'أقصى عدد ملفات متزامنة لكل تورنت'
                                : 'Max Concurrent Files Per Torrent',
                            subtitle: L10n.isRtl(context)
                                ? 'حد عدد الملفات التي يتم تحميلها بالتوازي في التورنت الواحد (0 = الكل)'
                                : 'Limit files downloading simultaneously per torrent (0 = all)',
                            value: settings.maxConcurrentFilesPerTorrent,
                            items: const [0, 1, 2, 3, 5, 10],
                            itemLabels: {
                              0: L10n.isRtl(context)
                                  ? 'الكل (غير محدود)'
                                  : 'All (Unlimited)',
                              1: '1',
                              2: '2',
                              3: '3',
                              5: '5',
                              10: '10',
                            },
                            onChanged: (val) {
                              if (val != null) {
                                settings.setMaxConcurrentFilesPerTorrent(val);
                                triggerHaptic(settings);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _stagger(
                      0.24,
                      _ConsoleSection(
                        index: '03',
                        title: L10n.of(context, 'settings_cockpit'),
                        accentColor: isDark
                            ? AppTheme.neonViolet
                            : AppTheme.lightNeonViolet,
                        isDark: isDark,
                        isExpanded: _expandedSections['cockpit'] ?? false,
                        onToggle: () {
                          triggerHaptic(settings);
                          setState(() {
                            _expandedSections['cockpit'] =
                                !(_expandedSections['cockpit'] ?? false);
                          });
                        },
                        children: [
                          _DropdownTile<String>(
                            accentColor: isDark
                                ? AppTheme.neonViolet
                                : AppTheme.lightNeonViolet,
                            title: L10n.isRtl(context)
                                ? 'سمة المظهر'
                                : 'THEME MODE',
                            subtitle: L10n.isRtl(context)
                                ? 'اختر سمة مظهر التطبيق'
                                : 'Select application theme mode',
                            value: settings.themeMode,
                            items: const ['light', 'dark', 'system'],
                            itemLabels: {
                              'light': L10n.isRtl(context) ? 'فاتح' : 'LIGHT',
                              'dark': L10n.isRtl(context) ? 'داكن' : 'DARK',
                              'system': L10n.isRtl(context)
                                  ? 'تلقائي'
                                  : 'SYSTEM DEFAULT',
                            },
                            onChanged: (val) {
                              if (val != null) {
                                settings.setThemeMode(val);
                                triggerHaptic(settings);
                              }
                            },
                          ),
                          _Divider(isDark: isDark),
                          _SwitchTile(
                            accentColor: isDark
                                ? AppTheme.neonViolet
                                : AppTheme.lightNeonViolet,
                            title: L10n.of(context, 'settings_classic_ui'),
                            subtitle: settings.batterySaverMode
                                ? (isRtl
                                    ? 'مفعل بواسطة موفر البطارية'
                                    : 'Forced ON by Battery Saver')
                                : L10n.of(context, 'settings_classic_ui_sub'),
                            value: settings.classicUi,
                            onChanged: settings.batterySaverMode
                                ? null
                                : (val) {
                                    settings.setClassicUi(val);
                                    triggerHaptic(settings);
                                  },
                          ),
                          _Divider(isDark: isDark),
                          _SwitchTile(
                            accentColor: isDark
                                ? AppTheme.neonViolet
                                : AppTheme.lightNeonViolet,
                            title: L10n.of(context, 'settings_glow'),
                            subtitle: L10n.of(context, 'settings_glow_sub'),
                            value: settings.enableGlow,
                            onChanged: (val) {
                              settings.setEnableGlow(val);
                              triggerHaptic(settings);
                            },
                          ),
                          _Divider(isDark: isDark),
                          _SliderTile(
                            accentColor: isDark
                                ? AppTheme.neonViolet
                                : AppTheme.lightNeonViolet,
                            title: L10n.of(context, 'settings_grid'),
                            valueLabel: '${settings.gridOpacity.toInt()}%',
                            subtitle: L10n.of(context, 'settings_grid_sub'),
                            value: settings.gridOpacity,
                            min: 0.0,
                            max: 40.0,
                            divisions: 8,
                            onChanged: (val) => settings.setGridOpacity(val),
                            onChangeEnd: (val) => triggerHaptic(settings),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _stagger(
                      0.32,
                      _ConsoleSection(
                        index: '04',
                        title: L10n.of(context, 'settings_alerters'),
                        accentColor: isDark
                            ? AppTheme.neonAmber
                            : AppTheme.lightNeonAmber,
                        isDark: isDark,
                        isExpanded: _expandedSections['alerters'] ?? false,
                        onToggle: () {
                          triggerHaptic(settings);
                          setState(() {
                            _expandedSections['alerters'] =
                                !(_expandedSections['alerters'] ?? false);
                          });
                        },
                        children: [
                          _SwitchTile(
                            accentColor: isDark
                                ? AppTheme.neonAmber
                                : AppTheme.lightNeonAmber,
                            title: L10n.isRtl(context)
                                ? 'الإشعارات العامة'
                                : 'GLOBAL NOTIFICATIONS',
                            subtitle: L10n.isRtl(context)
                                ? 'تفعيل أو تعطيل جميع إشعارات التطبيق'
                                : 'Enable or disable all app notifications',
                            value: settings.notificationsEnabled,
                            onChanged: (val) {
                              settings.setNotificationsEnabled(val);
                              triggerHaptic(settings);
                            },
                          ),
                          _Divider(isDark: isDark),
                          _SwitchTile(
                            accentColor: isDark
                                ? AppTheme.neonAmber
                                : AppTheme.lightNeonAmber,
                            title: L10n.of(context, 'settings_chime'),
                            subtitle: L10n.of(context, 'settings_chime_sub'),
                            value: settings.soundNotification,
                            onChanged: (val) {
                              settings.setSoundNotification(val);
                              triggerHaptic(settings);
                            },
                          ),
                          _Divider(isDark: isDark),
                          _SwitchTile(
                            accentColor: isDark
                                ? AppTheme.neonGreen
                                : AppTheme.lightNeonGreen,
                            title: L10n.of(context, 'settings_auto_retry'),
                            subtitle:
                                L10n.of(context, 'settings_auto_retry_sub'),
                            value: settings.autoRetryEnabled,
                            onChanged: (val) {
                              settings.setAutoRetryEnabled(val);
                              triggerHaptic(settings);
                            },
                          ),
                          // FIX(6): Max concurrent files per torrent setting
                          _Divider(isDark: isDark),
                          _DropdownTile<int>(
                            accentColor: isDark
                                ? AppTheme.neonGreen
                                : AppTheme.lightNeonGreen,
                            title: L10n.isRtl(context)
                                ? 'أقصى عدد ملفات متزامنة لكل تورنت'
                                : 'Max Concurrent Files Per Torrent',
                            subtitle: L10n.isRtl(context)
                                ? 'حد عدد الملفات التي تتم تحميلها بالتازي في التورنت الواحد (0 = الكل)'
                                : 'Limit files downloading simultaneously per torrent (0 = all)',
                            value: settings.maxConcurrentFilesPerTorrent,
                            items: const [0, 1, 2, 3, 5, 10],
                            itemLabels: {
                              0: L10n.isRtl(context)
                                  ? 'الكل (غير محدود)'
                                  : 'All (Unlimited)',
                              1: '1',
                              2: '2',
                              3: '3',
                              5: '5',
                              10: '10',
                            },
                            onChanged: (val) {
                              if (val != null) {
                                settings.setMaxConcurrentFilesPerTorrent(val);
                                triggerHaptic(settings);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _stagger(
                      0.40,
                      _ConsoleSection(
                        index: '05',
                        title: L10n.isRtl(context)
                            ? 'مراقب الأداء والتحكم بالنظام'
                            : 'TELEMETRY & PERFORMANCE',
                        accentColor:
                            isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan,
                        isDark: isDark,
                        isExpanded: _expandedSections['telemetry'] ?? false,
                        onToggle: () {
                          triggerHaptic(settings);
                          setState(() {
                            _expandedSections['telemetry'] =
                                !(_expandedSections['telemetry'] ?? false);
                          });
                        },
                        children: [PerformanceTelemetryCard(settings: settings)],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _stagger(
                      0.48,
                      _ConsoleSection(
                        index: '06',
                        title: L10n.of(context, 'settings_youtube_backend'),
                        accentColor:
                            isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                        isDark: isDark,
                        isExpanded: _expandedSections['backend'] ?? false,
                        onToggle: () {
                          triggerHaptic(settings);
                          setState(() {
                            _expandedSections['backend'] =
                                !(_expandedSections['backend'] ?? false);
                          });
                        },
                        children: [
                          _TextFieldTile(
                            accentColor: isDark
                                ? AppTheme.neonRed
                                : AppTheme.lightNeonRed,
                            title: L10n.isRtl(context)
                                ? 'عنوان الخادم الخلفي (URL)'
                                : 'Backend URL',
                            subtitle: L10n.isRtl(context)
                                ? 'عنوان الخادم الخلفي لـ yt-dlp (http/https)'
                                : 'Backend URL for yt-dlp (http:// or https://)',
                            controller: _backendUrlController,
                            onChanged: (val) =>
                                _onBackendUrlChanged(val, settings),
                            onSubmitted: (val) =>
                                _saveBackendUrl(val, settings),
                          ),
                          _Divider(isDark: isDark),
                          Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: NeonGlowButton(
                              isFilled: false,
                              color: isDark
                                  ? AppTheme.neonGreen
                                  : AppTheme.lightNeonGreen,
                              text: L10n.isRtl(context)
                                  ? 'اختبار الاتصال'
                                  : 'TEST CONNECTION',
                              onPressed: () async {
                                triggerHaptic(settings);
                                if (settings.backendUrl.isEmpty) {
                                  ThemedSnackbar.show(
                                    context,
                                    message: L10n.isRtl(context)
                                        ? 'يرجى تعيين عنوان الخادم الخلفي أولاً.'
                                        : 'Please configure backend URL first.',
                                    color: isDark
                                        ? AppTheme.neonRed
                                        : AppTheme.lightNeonRed,
                                    icon: Icons.error_outline,
                                    isDarkMode: isDark,
                                  );
                                  return;
                                }
                                ThemedSnackbar.show(
                                  context,
                                  message: L10n.isRtl(context)
                                      ? 'جاري اختبار الخادم الخلفي...'
                                      : 'Testing backend connection...',
                                  color: isDark
                                      ? AppTheme.neonBlue
                                      : AppTheme.lightNeonBlue,
                                  icon: Icons.sync,
                                  isDarkMode: isDark,
                                );
                                try {
                                  XdmBackendClient().refreshConfig();
                                  final response =
                                      await XdmBackendClient().health();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(
                                      context,
                                    ).hideCurrentSnackBar();
                                    final status =
                                        response['status'] as String? ??
                                            'unknown';
                                    if (status == 'ok') {
                                      ThemedSnackbar.show(
                                        context,
                                        message: L10n.isRtl(context)
                                            ? 'تم الاتصال! الخادم الخلفي يعمل.'
                                            : 'Backend connection successful!',
                                        color: isDark
                                            ? AppTheme.neonGreen
                                            : AppTheme.lightNeonGreen,
                                        icon: Icons.check_circle_outline,
                                        isDarkMode: isDark,
                                      );
                                    } else {
                                      ThemedSnackbar.show(
                                        context,
                                        message: L10n.isRtl(context)
                                            ? 'الخادم الخلفي لا يعمل (الحالة: $status)'
                                            : 'Backend not responding (status: $status)',
                                        color: isDark
                                            ? AppTheme.neonRed
                                            : AppTheme.lightNeonRed,
                                        icon: Icons.error_outline,
                                        isDarkMode: isDark,
                                      );
                                    }
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(
                                      context,
                                    ).hideCurrentSnackBar();
                                    ThemedSnackbar.show(
                                      context,
                                      message: L10n.isRtl(context)
                                          ? 'فشل في اختبار الاتصال: ${e.toString()}'
                                          : 'Connection test failed: $e',
                                      color: isDark
                                          ? AppTheme.neonRed
                                          : AppTheme.lightNeonRed,
                                      icon: Icons.error_outline,
                                      isDarkMode: isDark,
                                    );
                                  }
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _stagger(
                      0.56,
                      _ConsoleSection(
                        index: '07',
                        title: L10n.of(context, 'settings_adv_console'),
                        accentColor: isDark
                            ? AppTheme.neonBlue
                            : AppTheme.lightNeonBlue,
                        isDark: isDark,
                        isExpanded: _expandedSections['advanced'] ?? false,
                        onToggle: () {
                          triggerHaptic(settings);
                          setState(() {
                            _expandedSections['advanced'] =
                                !(_expandedSections['advanced'] ?? false);
                          });
                        },
                        children: [
                          _SwitchTile(
                            accentColor: isDark
                                ? AppTheme.neonBlue
                                : AppTheme.lightNeonBlue,
                            title: L10n.of(context, 'settings_subfolders'),
                            subtitle:
                                L10n.of(context, 'settings_subfolders_sub'),
                            value: settings.categoryFolders,
                            onChanged: (val) {
                              settings.setCategoryFolders(val);
                              triggerHaptic(settings);
                            },
                          ),
                          _Divider(isDark: isDark),
                          _TextFieldTile(
                            accentColor: isDark
                                ? AppTheme.neonBlue
                                : AppTheme.lightNeonBlue,
                            title: L10n.of(context, 'settings_ua'),
                            subtitle: L10n.of(context, 'settings_ua_sub'),
                            controller: _uaController,
                            onSubmitted: (val) =>
                                settings.setCustomUserAgent(val),
                          ),
                          _Divider(isDark: isDark),
                          _SwitchTile(
                            accentColor: isDark
                                ? AppTheme.neonBlue
                                : AppTheme.lightNeonBlue,
                            title: L10n.of(context, 'settings_bypass_ssl'),
                            subtitle:
                                L10n.of(context, 'settings_bypass_ssl_sub'),
                            value: settings.bypassSSL,
                            onChanged: (val) {
                              settings.setBypassSSL(val);
                              triggerHaptic(settings);
                              _maybeConfirmBypassSSL(context, settings);
                            },
                          ),
                          _Divider(isDark: isDark),
                          _SwitchTile(
                            accentColor: isDark
                                ? AppTheme.neonBlue
                                : AppTheme.lightNeonBlue,
                            title: L10n.of(context, 'settings_https_only'),
                            subtitle:
                                L10n.of(context, 'settings_https_only_sub'),
                            value: settings.httpsOnly,
                            onChanged: (val) {
                              settings.setHttpsOnly(val);
                              triggerHaptic(settings);
                            },
                          ),
                          _Divider(isDark: isDark),
                          _SwitchTile(
                            accentColor: isDark
                                ? AppTheme.neonBlue
                                : AppTheme.lightNeonBlue,
                            title: L10n.of(context, 'settings_proxy'),
                            subtitle: L10n.of(context, 'settings_proxy_sub'),
                            value: settings.enableProxy,
                            onChanged: (val) {
                              settings.setEnableProxy(val);
                              triggerHaptic(settings);
                            },
                          ),
                          if (settings.enableProxy) ...[
                            _Divider(isDark: isDark),
                            _TextFieldTile(
                              accentColor: isDark
                                  ? AppTheme.neonBlue
                                  : AppTheme.lightNeonBlue,
                              title: L10n.isRtl(context)
                                  ? 'عنوان الوكيل (Host)'
                                  : 'PROXY HOST',
                              subtitle: L10n.isRtl(context)
                                  ? 'اسم المضيف أو عنوان IP'
                                  : 'Host name or IP address',
                              controller: _proxyHostController,
                              onSubmitted: (val) {
                                settings.setProxyHost(val.trim());
                                settings.setProxyAddress(
                                  '${val.trim()}:${settings.proxyPort}',
                                );
                              },
                            ),
                            _Divider(isDark: isDark),
                            _TextFieldTile(
                              accentColor: isDark
                                  ? AppTheme.neonBlue
                                  : AppTheme.lightNeonBlue,
                              title: L10n.isRtl(context)
                                  ? 'منفذ الوكيل (Port)'
                                  : 'PROXY PORT',
                              subtitle: L10n.isRtl(context)
                                  ? 'منفذ الاتصال بالوكيل'
                                  : 'Port number for connection',
                              controller: _proxyPortController,
                              onSubmitted: (val) {
                                final port = int.tryParse(val.trim()) ?? 8080;
                                settings.setProxyPort(port);
                                settings.setProxyAddress(
                                  '${settings.proxyHost}:$port',
                                );
                              },
                            ),
                          ],
                          _Divider(isDark: isDark),
                          Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: NeonGlowButton(
                              isFilled: false,
                              color: isDark
                                  ? AppTheme.neonRed
                                  : AppTheme.lightNeonRed,
                              text: L10n.isRtl(context)
                                  ? 'إعادة تعيين إلى الافتراضيات'
                                  : 'RESET TO DEFAULTS',
                              onPressed: () async {
                                triggerHaptic(settings);
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    backgroundColor: isDark
                                        ? AppTheme.surface
                                        : AppTheme.lightSurface,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                      side: BorderSide(
                                        color: isDark
                                            ? AppTheme.neonRed
                                            : AppTheme.lightNeonRed,
                                        width: 1.0,
                                      ),
                                    ),
                                    title: Text(
                                      L10n.isRtl(context)
                                          ? 'إعادة تعيين الإعدادات'
                                          : 'RESET SETTINGS',
                                      style: TextStyle(
                                        color: isDark
                                            ? AppTheme.neonRed
                                            : AppTheme.lightNeonRed,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    content: Text(
                                      L10n.isRtl(context)
                                          ? 'هل أنت متأكد من رغبتك في إعادة تعيين جميع الإعدادات إلى القيم الافتراضية؟'
                                          : 'Are you sure you want to reset all settings to their default values?',
                                      style: TextStyle(
                                        color: isDark
                                            ? AppTheme.textPrimary
                                            : AppTheme.lightTextPrimary,
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(context, false),
                                        child: Text(
                                          L10n.isRtl(context)
                                              ? 'إلغاء'
                                              : 'CANCEL',
                                          style: TextStyle(
                                            color: isDark
                                                ? AppTheme.textSecondary
                                                : AppTheme.lightTextSecondary,
                                          ),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(context, true),
                                        child: Text(
                                          L10n.isRtl(context)
                                              ? 'إعادة تعيين'
                                              : 'RESET',
                                          style: TextStyle(
                                            color: isDark
                                                ? AppTheme.neonRed
                                                : AppTheme.lightNeonRed,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  await settings.resetToDefaults();
                                  _uaController.text =
                                      settings.customUserAgent;
                                  _proxyHostController.text =
                                      settings.proxyHost;
                                  _proxyPortController.text =
                                      settings.proxyPort.toString();
                                  _proxyUsernameController.text =
                                      settings.proxyUsername;
                                  _proxyPasswordController.text =
                                      settings.proxyPassword;
                                  if (context.mounted) {
                                    ThemedSnackbar.show(
                                      context,
                                      message: L10n.isRtl(context)
                                          ? 'تمت إعادة تعيين الإعدادات بنجاح!'
                                          : 'Settings reset to default values!',
                                      color: isDark
                                          ? AppTheme.neonGreen
                                          : AppTheme.lightNeonGreen,
                                      icon: Icons.check_circle_outline,
                                      isDarkMode: isDark,
                                    );
                                  }
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _stagger(
                      0.64,
                      _ConsoleSection(
                        index: '08',
                        title: L10n.of(context, 'settings_adblock_title'),
                        accentColor: isDark
                            ? AppTheme.neonGreen
                            : AppTheme.lightNeonGreen,
                        isDark: isDark,
                        isExpanded: _expandedSections['adblock'] ?? false,
                        onToggle: () {
                          triggerHaptic(settings);
                          setState(() {
                            _expandedSections['adblock'] =
                                !(_expandedSections['adblock'] ?? false);
                          });
                        },
                        children: [
                          _SwitchTile(
                            accentColor: isDark
                                ? AppTheme.neonGreen
                                : AppTheme.lightNeonGreen,
                            title: L10n.of(context, 'settings_enable_adblock'),
                            subtitle:
                                L10n.of(context, 'settings_enable_adblock_sub'),
                            value: AdBlockerService.instance.isEnabled,
                            onChanged: (val) async {
                              await AdBlockerService.instance.setEnabled(val);
                              triggerHaptic(settings);
                              setState(() {});
                            },
                          ),
                          _Divider(isDark: isDark),
                          Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  '${L10n.of(context, 'settings_adblock_rules')}: ${AdBlockerService.instance.ruleCount}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? AppTheme.textSecondary
                                        : AppTheme.lightTextSecondary,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                NeonGlowButton(
                                  isFilled: false,
                                  color: isDark
                                      ? AppTheme.neonGreen
                                      : AppTheme.lightNeonGreen,
                                  text: _isUpdatingAdBlock
                                      ? L10n.of(context,
                                          'settings_updating_adblock_hosts')
                                      : L10n.of(context,
                                          'settings_update_adblock_hosts'),
                                  onPressed: _isUpdatingAdBlock
                                      ? null
                                      : () async {
                                          triggerHaptic(settings);
                                          setState(
                                              () => _isUpdatingAdBlock = true);
                                          ThemedSnackbar.show(
                                            context,
                                            message: L10n.of(
                                              context,
                                              'settings_adblock_updating_msg',
                                            ),
                                            color: isDark
                                                ? AppTheme.neonBlue
                                                : AppTheme.lightNeonBlue,
                                            icon: Icons.sync,
                                            isDarkMode: isDark,
                                          );
                                          final success = await AdBlockerService
                                              .instance
                                              .updateFilters(force: true);
                                          if (mounted && context.mounted) {
                                            setState(() =>
                                                _isUpdatingAdBlock = false);
                                            ScaffoldMessenger.of(context)
                                                .hideCurrentSnackBar();
                                            if (success) {
                                              ThemedSnackbar.show(
                                                context,
                                                message:
                                                    '${L10n.of(context, 'settings_adblock_success_msg')} (${AdBlockerService.instance.ruleCount})',
                                                color: isDark
                                                    ? AppTheme.neonGreen
                                                    : AppTheme.lightNeonGreen,
                                                icon: Icons
                                                    .check_circle_outline,
                                                isDarkMode: isDark,
                                              );
                                            } else {
                                              ThemedSnackbar.show(
                                                context,
                                                message: L10n.of(
                                                  context,
                                                  'settings_adblock_failed_msg',
                                                ),
                                                color: isDark
                                                    ? AppTheme.neonRed
                                                    : AppTheme.lightNeonRed,
                                                icon: Icons.error_outline,
                                                isDarkMode: isDark,
                                              );
                                            }
                                          }
                                        },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _stagger(
                      0.65,
                      _ConsoleSection(
                        index: '08b',
                        title: L10n.isRtl(context)
                            ? 'مضيفو حجب الإعلانات المخصصون'
                            : 'CUSTOM AD-BLOCK HOSTS',
                        accentColor: isDark
                            ? AppTheme.neonGreen
                            : AppTheme.lightNeonGreen,
                        isDark: isDark,
                        isExpanded:
                            _expandedSections['custom_adblock'] ?? false,
                        onToggle: () {
                          triggerHaptic(settings);
                          setState(() {
                            _expandedSections['custom_adblock'] =
                                !(_expandedSections['custom_adblock'] ?? false);
                          });
                        },
                        children: [
                          _CustomAdBlockModule(
                            isDark: isDark,
                            onRefresh: () =>
                                AdBlockerService.instance.refresh(),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _stagger(
                      0.655,
                      _ConsoleSection(
                        index: '08c',
                        title: L10n.isRtl(context)
                            ? 'إعدادات DNS المخصصة (DoH)'
                            : 'CUSTOM DNS (DoH) SETTINGS',
                        accentColor:
                            isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                        isDark: isDark,
                        isExpanded: _expandedSections['custom_dns'] ?? false,
                        onToggle: () {
                          triggerHaptic(settings);
                          setState(() {
                            _expandedSections['custom_dns'] =
                                !(_expandedSections['custom_dns'] ?? false);
                          });
                        },
                        children: [
                          _CustomDnsModule(
                            settings: settings,
                            isDark: isDark,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _stagger(
                      0.66,
                      _ConsoleSection(
                        index: '09',
                        title: L10n.of(context, 'settings_accessibility_title'),
                        accentColor:
                            isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                        isDark: isDark,
                        isExpanded: _expandedSections['accessibility'] ?? false,
                        onToggle: () {
                          triggerHaptic(settings);
                          setState(() {
                            _expandedSections['accessibility'] =
                                !(_expandedSections['accessibility'] ?? false);
                          });
                        },
                        children: [
                          _SwitchTile(
                            accentColor: isDark
                                ? AppTheme.neonBlue
                                : AppTheme.lightNeonBlue,
                            title: isRtl
                                ? 'تقليل المؤثرات البصرية'
                                : 'REDUCE MOTION & VISUALS',
                            subtitle: isRtl
                                ? 'إيقاف تأثيرات التوهج والضبابية لتحسين سهولة القراءة والأداء'
                                : 'Disable animation, glow, and blur effects to improve readability and performance',
                            value: settings.reduceVisuals,
                            onChanged: (val) {
                              settings.setReduceVisuals(val);
                              triggerHaptic(settings);
                            },
                          ),
                          _Divider(isDark: isDark),
                          _SliderTile(
                            accentColor: isDark
                                ? AppTheme.neonBlue
                                : AppTheme.lightNeonBlue,
                            title: L10n.of(context, 'settings_text_scaling'),
                            valueLabel:
                                '${(settings.textScaleFactor * 100).toInt()}%',
                            subtitle:
                                L10n.of(context, 'settings_text_scaling_sub'),
                            value: settings.textScaleFactor,
                            min: 0.8,
                            max: 2.0,
                            divisions: 12,
                            onChanged: (val) =>
                                settings.setTextScaleFactor(val),
                            onChangeEnd: (val) => triggerHaptic(settings),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _stagger(0.70, _BackupModule(settings: settings)),
                    const SizedBox(height: 14),
                    _stagger(0.74, _CommsModule(settings: settings)),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// System Header — opens the screen with live status
// ─────────────────────────────────────────────────────────────
class _SystemHeader extends StatefulWidget {
  final SettingsProvider settings;
  const _SystemHeader({required this.settings});

  @override
  State<_SystemHeader> createState() => _SystemHeaderState();
}

class _SystemHeaderState extends State<_SystemHeader>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.settings.isDarkMode;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.surfaceRaised : AppTheme.lightSurfaceRaised,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: violetClr.withValues(alpha: 0.25), width: 1),
        boxShadow: [AppTheme.glow(violetClr, alpha: 0.10, blur: 24)],
      ),
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          DmxAppIcon(size: 50, customColor: violetClr, showGlow: true),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  L10n.of(context, 'app_title'),
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.textPrimary
                        : AppTheme.lightTextPrimary,
                    fontFamily: 'Space Grotesk',
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${L10n.of(context, 'settings_firmware')} v$kAppVersion',
                  style: TextStyle(
                    color:
                        isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                    fontFamily: 'Space Grotesk',
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    AnimatedBuilder(
                      animation: _controller,
                      builder: (context, child) {
                        return Opacity(
                          opacity: 0.4 + (_controller.value * 0.6),
                          child: Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: greenClr,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: greenClr.withValues(alpha: 0.5),
                                  blurRadius: 5,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 6),
                    Text(
                      L10n.isRtl(context)
                          ? 'النظام يعمل بشكل طبيعي'
                          : 'ALL SYSTEMS NOMINAL',
                      style: TextStyle(
                        color: greenClr,
                        fontFamily: 'Space Grotesk',
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () async {
              ThemedSnackbar.show(
                context,
                message: L10n.isRtl(context)
                    ? 'جاري التحقق من وجود تحديثات...'
                    : 'Checking for updates...',
                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                icon: Icons.sync,
                isDarkMode: isDark,
              );
              final update = await UpdateService().checkForUpdate();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              final provider = context.read<DownloadProvider>();
              if (update != null) {
                showUpdateInfoDialog(
                  context,
                  update,
                  provider,
                  widget.settings,
                );
              } else {
                ThemedSnackbar.show(
                  context,
                  message: L10n.isRtl(context)
                      ? 'التطبيق محدّث لأحدث إصدار!'
                      : 'App is up to date!',
                  color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                  icon: Icons.check_circle_outline,
                  isDarkMode: isDark,
                );
              }
            },
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: violetClr.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: violetClr.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Icon(
                Icons.system_update_rounded,
                color: violetClr,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// HUD Reusable Container
// ─────────────────────────────────────────────────────────────
class _HudContainer extends StatelessWidget {
  final Color accentColor;
  final bool isDark;
  final Widget child;
  final EdgeInsets padding;

  const _HudContainer({
    required this.accentColor,
    required this.isDark,
    required this.child,
  }) : padding = const EdgeInsets.all(20);

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          width: double.infinity,
          decoration: AppTheme.panel(
            isDark: isDark,
            accentColor: accentColor,
            accentAlpha: 0.15,
          ),
          padding: padding,
          child: child,
        ),
        Positioned(
          top: 8,
          left: 8,
          child: _HudCorner(color: accentColor, alignment: Alignment.topLeft),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: _HudCorner(color: accentColor, alignment: Alignment.topRight),
        ),
        Positioned(
          bottom: 8,
          left: 8,
          child: _HudCorner(
            color: accentColor,
            alignment: Alignment.bottomLeft,
          ),
        ),
        Positioned(
          bottom: 8,
          right: 8,
          child: _HudCorner(
            color: accentColor,
            alignment: Alignment.bottomRight,
          ),
        ),
      ],
    );
  }
}

class _HudCorner extends StatelessWidget {
  final Color color;
  final Alignment alignment;
  const _HudCorner({required this.color, required this.alignment});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 12,
      height: 12,
      child: CustomPaint(
        painter: _HudCornerPainter(color: color, alignment: alignment),
      ),
    );
  }
}

class _HudCornerPainter extends CustomPainter {
  final Color color;
  final Alignment alignment;
  _HudCornerPainter({required this.color, required this.alignment});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    if (alignment == Alignment.topLeft) {
      path.moveTo(0, size.height * 0.5);
      path.lineTo(0, 0);
      path.lineTo(size.width * 0.5, 0);
    } else if (alignment == Alignment.topRight) {
      path.moveTo(size.width * 0.5, 0);
      path.lineTo(size.width, 0);
      path.lineTo(size.width, size.height * 0.5);
    } else if (alignment == Alignment.bottomLeft) {
      path.moveTo(0, size.height * 0.5);
      path.lineTo(0, size.height);
      path.lineTo(size.width * 0.5, size.height);
    } else {
      path.moveTo(size.width * 0.5, size.height);
      path.lineTo(size.width, size.height);
      path.lineTo(size.width, size.height * 0.5);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─────────────────────────────────────────────────────────────
// Console Section — numbered, expandable module
// ─────────────────────────────────────────────────────────────
class _ConsoleSection extends StatelessWidget {
  final String index;
  final String title;
  final Color accentColor; // NEW
  final bool isDark;
  final bool isExpanded;
  final VoidCallback onToggle;
  final List<Widget> children;

  const _ConsoleSection({
    required this.index,
    required this.title,
    required this.accentColor,
    required this.isDark,
    required this.isExpanded,
    required this.onToggle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.surfaceRaised : AppTheme.lightSurfaceRaised,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: accentColor.withValues(alpha: isExpanded ? 0.34 : 0.18),
          width: 1.05,
        ),
        boxShadow: [
          BoxShadow(
            color: accentColor.withValues(alpha: isExpanded ? 0.14 : 0.06),
            blurRadius: isExpanded ? 18 : 10,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: (isDark ? Colors.black : Colors.white).withValues(
              alpha: 0.08,
            ),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 18.0,
                vertical: 16.0,
              ),
              child: Row(
                children: [
                  Text(
                    '[ $index ]',
                    style: TextStyle(
                      color: accentColor,
                      fontFamily: 'Space Grotesk',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 1,
                    height: 16,
                    color: accentColor.withValues(alpha: 0.24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.textPrimary
                            : AppTheme.lightTextPrimary,
                        fontFamily: 'Space Grotesk',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                  if (isExpanded)
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsetsDirectional.only(end: 8),
                      decoration: BoxDecoration(
                        color: accentColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(color: accentColor, blurRadius: 6),
                        ],
                      ),
                    ),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0,
                    duration: AppTheme.motionBase,
                    curve: AppTheme.motionCurve,
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 18,
                      color: isDark
                          ? AppTheme.textSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Divider(color: accentColor.withValues(alpha: 0.2), height: 1),
                ...children,
              ],
            ),
            crossFadeState: isExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: AppTheme.motionBase,
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  final bool isDark;
  const _Divider({required this.isDark});
  @override
  Widget build(BuildContext context) {
    return Divider(
      color: isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
      height: 1,
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Tiles
// ─────────────────────────────────────────────────────────────
class _SwitchTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color accentColor; // NEW

  const _SwitchTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? AppTheme.surface : AppTheme.lightSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: accentColor.withValues(alpha: 0.16),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: accentColor.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: SwitchListTile(
            value: value,
            onChanged: onChanged,
            activeThumbColor: accentColor,
            activeTrackColor: accentColor.withValues(alpha: 0.3),
            inactiveThumbColor:
                isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
            inactiveTrackColor:
                isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 6,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            title: Text(
              title,
              style: TextStyle(
                color:
                    isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                fontFamily: 'Space Grotesk',
                fontSize: 14.0,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(
                color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                fontFamily: 'Inter',
                fontSize: 12.0,
                height: 1.35,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final Color accentColor;

  const _SliderTile({
    required this.title,
    this.subtitle,
    this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.onChangeEnd,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    String badgeText = valueLabel ?? '';
    String? descriptionText = subtitle;

    if (badgeText.isEmpty && subtitle != null) {
      final spaceIndex = subtitle!.indexOf(' ');
      if (spaceIndex > 0 &&
          (subtitle!.startsWith(RegExp(r'\d')) || subtitle!.endsWith('%'))) {
        badgeText = subtitle!.substring(0, spaceIndex);
        descriptionText = subtitle!.substring(spaceIndex + 1);
      } else {
        badgeText = subtitle!;
        descriptionText = null;
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.surface : AppTheme.lightSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: accentColor.withValues(alpha: 0.16),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: accentColor.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.textPrimary
                              : AppTheme.lightTextPrimary,
                          fontFamily: 'Space Grotesk',
                          fontSize: 14.0,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (descriptionText != null &&
                          descriptionText.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          descriptionText.trim(),
                          style: TextStyle(
                            color: isDark
                                ? AppTheme.textMuted
                                : AppTheme.lightTextMuted,
                            fontFamily: 'Inter',
                            fontSize: 12.0,
                            height: 1.35,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (badgeText.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: accentColor.withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      badgeText,
                      style: TextStyle(
                        color: accentColor,
                        fontFamily: 'Space Grotesk',
                        fontSize: 12.0,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: accentColor,
                inactiveTrackColor:
                    isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
                thumbColor: accentColor,
                overlayColor: accentColor.withValues(alpha: 0.2),
                trackHeight: 4.0,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 7.0,
                ),
                overlayShape: const RoundSliderOverlayShape(
                  overlayRadius: 16.0,
                ),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DropdownTile<T> extends StatelessWidget {
  final String title;
  final String subtitle;
  final T value;
  final List<T> items;
  final Map<T, String>? itemLabels;
  final ValueChanged<T?>? onChanged;
  final Color accentColor; // NEW

  const _DropdownTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.items,
    this.itemLabels,
    required this.onChanged,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.surface : AppTheme.lightSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: accentColor.withValues(alpha: 0.16),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: accentColor.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textPrimary
                          : AppTheme.lightTextPrimary,
                      fontFamily: 'Space Grotesk',
                      fontSize: 14.0,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color:
                          isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                      fontFamily: 'Inter',
                      fontSize: 12.0,
                      height: 1.35,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 90,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: accentColor.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<T>(
                  isDense: true,
                  isExpanded: true,
                  dropdownColor:
                      isDark ? AppTheme.surface : AppTheme.lightSurface,
                  borderRadius: BorderRadius.circular(14),
                  elevation: 4,
                  menuMaxHeight: 250,
                  value: value,
                  icon: Icon(
                    Icons.expand_more_rounded,
                    color: accentColor,
                    size: 18,
                  ),
                  style: TextStyle(
                    color: accentColor,
                    fontFamily: 'Space Grotesk',
                    fontSize: 12.0,
                    fontWeight: FontWeight.w500,
                  ),
                  items: items.map((item) {
                    return DropdownMenuItem<T>(
                      value: item,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          itemLabels != null
                              ? itemLabels![item]!
                              : item.toString(),
                          style: TextStyle(
                            color: isDark
                                ? AppTheme.textPrimary
                                : AppTheme.lightTextPrimary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                  onChanged: onChanged,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextFieldTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Color accentColor;

  const _TextFieldTile({
    required this.title,
    required this.subtitle,
    required this.controller,
    this.onChanged,
    this.onSubmitted,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.surface : AppTheme.lightSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: accentColor.withValues(alpha: 0.16),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: accentColor.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color:
                    isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                fontFamily: 'Space Grotesk',
                fontSize: 14.0,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                fontFamily: 'Inter',
                fontSize: 12.0,
                height: 1.35,
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: isDark
                    ? AppTheme.surfaceRaised
                    : AppTheme.lightSurfaceRaised,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: accentColor.withValues(alpha: 0.24),
                  width: 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: TextField(
                  controller: controller,
                  onChanged: onChanged,
                  onSubmitted: onSubmitted,
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.textPrimary
                        : AppTheme.lightTextPrimary,
                    fontFamily: 'Inter',
                    fontSize: 12,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: accentColor.withValues(alpha: 0.4),
                        width: 1,
                      ),
                    ),
                    hintText: subtitle,
                    hintStyle: TextStyle(
                      color:
                          isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                      fontFamily: 'Inter',
                      fontSize: 12,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PathPickerTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  final Color accentColor; // NEW

  const _PathPickerTile({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onClear,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? AppTheme.surface : AppTheme.lightSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: accentColor.withValues(alpha: 0.16),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: accentColor.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            title: Text(
              title,
              style: TextStyle(
                color:
                    isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                fontFamily: 'Space Grotesk',
                fontSize: 14.0,
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(
                color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                fontFamily: 'Inter',
                fontSize: 12.0,
                height: 1.35,
                fontWeight: FontWeight.w400,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onClear != null)
                  IconButton(
                    icon: Icon(
                      Icons.clear,
                      color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                      size: 18,
                    ),
                    tooltip: L10n.isRtl(context)
                        ? 'إعادة تعيين الافتراضي'
                        : 'Reset to default',
                    onPressed: onClear,
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(
                      color: accentColor.withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                  child: Icon(Icons.folder_open, size: 16, color: accentColor),
                ),
              ],
            ),
            onTap: onTap,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Backup Module
// ─────────────────────────────────────────────────────────────
class _BackupModule extends StatelessWidget with HapticHelper {
  final SettingsProvider settings;
  const _BackupModule({required this.settings});

  @override
  Widget build(BuildContext context) {
    final isDark = settings.isDarkMode;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;

    return _HudContainer(
      accentColor: violetClr,
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.backup_rounded, color: violetClr, size: 16),
              const SizedBox(width: 8),
              Text(
                L10n.of(context, 'settings_backup_title'),
                style: TextStyle(
                  color:
                      isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                  fontFamily: 'Space Grotesk',
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            L10n.of(context, 'settings_backup_sub'),
            style: TextStyle(
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
              fontFamily: 'Space Grotesk',
              fontSize: 11,
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: NeonGlowButton(
                  isFilled: false,
                  color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                  onPressed: () =>
                      _BackupHelper.exportBackup(context, settings),
                  text: L10n.of(context, 'settings_export'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: NeonGlowButton(
                  isFilled: true,
                  color: violetClr,
                  onPressed: () =>
                      _BackupHelper.importBackup(context, settings),
                  text: L10n.of(context, 'settings_import'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Comms / Developer Module
// ─────────────────────────────────────────────────────────────
class _CommsModule extends StatelessWidget with HapticHelper {
  final SettingsProvider settings;
  const _CommsModule({required this.settings});

  @override
  Widget build(BuildContext context) {
    final isDark = settings.isDarkMode;
    final cyanClr = isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan;

    return _HudContainer(
      accentColor: cyanClr,
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.contact_mail_outlined, color: cyanClr, size: 16),
              const SizedBox(width: 8),
              Text(
                L10n.of(context, 'settings_developer'),
                style: TextStyle(
                  color:
                      isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                  fontFamily: 'Space Grotesk',
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ContactTile(
            accentColor: cyanClr,
            iconWidget: Icon(Icons.person_outline, size: 16, color: cyanClr),
            label: kDeveloperName,
            subtitle: L10n.of(context, 'developer_title'),
            isDark: isDark,
          ),
          const SizedBox(height: 8),
          _ContactTile(
            accentColor: cyanClr,
            iconWidget: FaIcon(
              FontAwesomeIcons.google,
              size: 16,
              color: cyanClr,
            ),
            label: kDeveloperEmail,
            subtitle: L10n.of(context, 'tap_to_open'),
            isDark: isDark,
            url: 'mailto:$kDeveloperEmail',
          ),
          const SizedBox(height: 8),
          _ContactTile(
            accentColor: cyanClr,
            iconWidget: FaIcon(
              FontAwesomeIcons.github,
              size: 16,
              color: cyanClr,
            ),
            label: kDeveloperGithub,
            subtitle: L10n.of(context, 'tap_to_open'),
            isDark: isDark,
            url: 'https://$kDeveloperGithub',
          ),
          const SizedBox(height: 8),
          _ContactTile(
            accentColor: cyanClr,
            iconWidget: FaIcon(
              FontAwesomeIcons.linkedin,
              size: 16,
              color: cyanClr,
            ),
            label: kDeveloperLinkedin,
            subtitle: L10n.of(context, 'tap_to_open'),
            isDark: isDark,
            url: 'https://$kDeveloperLinkedin',
          ),
        ],
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  final Widget iconWidget;
  final String label;
  final String subtitle;
  final bool isDark;
  final String? url;
  final Color accentColor;

  const _ContactTile({
    required this.iconWidget,
    required this.label,
    required this.subtitle,
    required this.isDark,
    required this.accentColor,
    this.url,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: url != null
          ? () async {
              final uri = Uri.tryParse(url!);
              if (uri != null && await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              } else {
                Clipboard.setData(ClipboardData(text: url!));
                if (context.mounted) {
                  ThemedSnackbar.show(
                    context,
                    message: L10n.of(context, 'copied'),
                    color:
                        isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                    icon: Icons.check_circle_outline,
                    isDarkMode: isDark,
                  );
                }
              }
            }
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: accentColor.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: accentColor.withValues(alpha: 0.2),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: accentColor.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            iconWidget,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textPrimary
                          : AppTheme.lightTextPrimary,
                      fontFamily: 'Space Grotesk',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color:
                          isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                      fontFamily: 'Space Grotesk',
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            if (url != null)
              Icon(
                Icons.open_in_new_rounded,
                size: 14,
                color: accentColor.withValues(alpha: 0.6),
              ),
          ],
        ),
      ),
    );
  }
}

class _CustomDnsModule extends StatefulWidget {
  final SettingsProvider settings;
  final bool isDark;

  const _CustomDnsModule({
    required this.settings,
    required this.isDark,
  });

  @override
  State<_CustomDnsModule> createState() => _CustomDnsModuleState();
}

class _CustomDnsModuleState extends State<_CustomDnsModule> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.settings.dnsProvider);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accentColor =
        widget.isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final isRtl = L10n.isRtl(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SwitchTile(
          accentColor: accentColor,
          title: isRtl ? 'تفعيل DNS المخصص (DoH)' : 'ENABLE CUSTOM DNS (DoH)',
          subtitle: isRtl
              ? 'تشفير طلبات DNS وتجاوز مزود الخدمة المحلي'
              : 'Encrypt DNS queries and bypass local ISP resolvers',
          value: widget.settings.dnsEnabled,
          onChanged: (val) => widget.settings.setDnsEnabled(val),
        ),
        _Divider(isDark: widget.isDark),
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TextFieldTile(
                accentColor: accentColor,
                title: isRtl ? 'مزود DoH' : 'DoH PROVIDER',
                subtitle: isRtl
                    ? 'عنوان المضيف (مثلاً dns.adguard.com)'
                    : 'Provider hostname (e.g. dns.adguard.com)',
                controller: _controller,
                onSubmitted: (val) => widget.settings.setDnsProvider(val),
                onChanged: (val) => widget.settings.setDnsProvider(val),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  _DnsChip(
                    label: 'AdGuard',
                    host: 'dns.adguard.com',
                    selected: widget.settings.dnsProvider == 'dns.adguard.com',
                    onTap: () {
                      _controller.text = 'dns.adguard.com';
                      widget.settings.setDnsProvider('dns.adguard.com');
                      setState(() {});
                    },
                    isDark: widget.isDark,
                  ),
                  _DnsChip(
                    label: 'Cloudflare',
                    host: 'cloudflare-dns.com',
                    selected:
                        widget.settings.dnsProvider == 'cloudflare-dns.com',
                    onTap: () {
                      _controller.text = 'cloudflare-dns.com';
                      widget.settings.setDnsProvider('cloudflare-dns.com');
                      setState(() {});
                    },
                    isDark: widget.isDark,
                  ),
                  _DnsChip(
                    label: 'Google',
                    host: 'dns.google',
                    selected: widget.settings.dnsProvider == 'dns.google',
                    onTap: () {
                      _controller.text = 'dns.google';
                      widget.settings.setDnsProvider('dns.google');
                      setState(() {});
                    },
                    isDark: widget.isDark,
                  ),
                  _DnsChip(
                    label: 'Quad9',
                    host: 'dns.quad9.net',
                    selected: widget.settings.dnsProvider == 'dns.quad9.net',
                    onTap: () {
                      _controller.text = 'dns.quad9.net';
                      widget.settings.setDnsProvider('dns.quad9.net');
                      setState(() {});
                    },
                    isDark: widget.isDark,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              NeonGlowButton(
                isFilled: false,
                color: widget.isDark
                    ? AppTheme.neonGreen
                    : AppTheme.lightNeonGreen,
                text: isRtl ? 'اختبار الاتصال' : 'TEST CONNECTION',
                onPressed: () async {
                  ThemedSnackbar.show(
                    context,
                    message: isRtl ? 'جاري اختبار الاتصال...' : 'Testing resolution...',
                    color: accentColor,
                    isDarkMode: widget.isDark,
                    icon: Icons.sync,
                  );
                  final ip = await DohResolver.instance.resolve(
                    'google.com',
                    widget.settings.dnsProvider,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    if (ip != null) {
                      ThemedSnackbar.show(
                        context,
                        message: isRtl
                            ? 'تم الاتصال! تم التحويل إلى $ip'
                            : 'Success: Resolved to $ip',
                        color: AppTheme.neonGreen,
                        icon: Icons.check_circle_outline,
                        isDarkMode: widget.isDark,
                      );
                    } else {
                      ThemedSnackbar.show(
                        context,
                        message: isRtl
                            ? 'فشل الاتصال عبر ${widget.settings.dnsProvider}'
                            : 'Failed to resolve via ${widget.settings.dnsProvider}',
                        color: AppTheme.neonRed,
                        icon: Icons.error_outline,
                        isDarkMode: widget.isDark,
                      );
                    }
                  }
                },
              ),
              const SizedBox(height: 12),
              Text(
                isRtl
                    ? '* ينطبق هذا على التحميلات وتحديثات الفلاتر والمتصفح المدمج.'
                    : '* This applies to downloads, filter updates, and the in-app browser.',
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'Inter',
                  color: widget.isDark
                      ? AppTheme.textMuted
                      : AppTheme.lightTextMuted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DnsChip extends StatelessWidget {
  final String label;
  final String host;
  final bool selected;
  final VoidCallback onTap;
  final bool isDark;

  const _DnsChip({
    required this.label,
    required this.host,
    required this.selected,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    return ActionChip(
      label: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.white : color,
          fontSize: 11,
          fontFamily: 'Space Grotesk',
          fontWeight: FontWeight.bold,
        ),
      ),
      backgroundColor: selected
          ? color
          : (isDark ? AppTheme.surface : AppTheme.lightSurface),
      side: BorderSide(color: color.withValues(alpha: 0.3)),
      onPressed: onTap,
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Custom Ad-Block Hosts Module
// ─────────────────────────────────────────────────────────────
class _CustomAdBlockModule extends StatefulWidget {
  final bool isDark;
  final VoidCallback onRefresh;

  const _CustomAdBlockModule({
    required this.isDark,
    required this.onRefresh,
  });

  @override
  State<_CustomAdBlockModule> createState() => _CustomAdBlockModuleState();
}

class _CustomAdBlockModuleState extends State<_CustomAdBlockModule> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = CustomAdBlockStore.instance;
    final accentColor =
        widget.isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final isRtl = L10n.isRtl(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SwitchTile(
          accentColor: accentColor,
          title: isRtl ? 'استخدام المضيفين المخصصين فقط' : 'USE CUSTOM ONLY',
          subtitle: isRtl
              ? 'تجاهل القوائم المحملة واستخدام المضيفين المذكورين أدناه فقط'
              : 'Ignore downloaded lists and only use hosts listed below',
          value: store.useCustomOnly,
          onChanged: (val) async {
            await store.setUseCustomOnly(val);
            widget.onRefresh();
            setState(() {});
          },
        ),
        _Divider(isDark: widget.isDark),
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _controller,
                maxLines: 3,
                style: TextStyle(
                  color: widget.isDark
                      ? AppTheme.textPrimary
                      : AppTheme.lightTextPrimary,
                  fontSize: 13,
                  fontFamily: 'Inter',
                ),
                decoration: InputDecoration(
                  hintText: isRtl
                      ? 'أدخل النطاقات (فاصلة أو سطر جديد)...'
                      : 'Enter domains (comma or newline separated)...',
                  hintStyle: TextStyle(
                    color: widget.isDark
                        ? AppTheme.textMuted
                        : AppTheme.lightTextMuted,
                  ),
                  filled: true,
                  fillColor:
                      widget.isDark ? AppTheme.surface : AppTheme.lightSurface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        BorderSide(color: accentColor.withValues(alpha: 0.3)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: accentColor),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              NeonGlowButton(
                color: accentColor,
                text: isRtl ? 'إضافة المضيفين' : 'ADD HOSTS',
                onPressed: () async {
                  if (_controller.text.trim().isEmpty) return;
                  await store.addHosts(_controller.text);
                  _controller.clear();
                  widget.onRefresh();
                  setState(() {});
                },
              ),
            ],
          ),
        ),
        if (store.hosts.isNotEmpty) ...[
          _Divider(isDark: widget.isDark),
          Container(
            constraints: const BoxConstraints(maxHeight: 250),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: store.hosts.length,
              itemBuilder: (context, index) {
                final host = store.hosts.elementAt(index);
                return ListTile(
                  dense: true,
                  title: Text(
                    host,
                    style: TextStyle(
                      color: widget.isDark
                          ? AppTheme.textPrimary
                          : AppTheme.lightTextPrimary,
                      fontSize: 13,
                      fontFamily: 'Space Grotesk',
                    ),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    color: AppTheme.neonRed,
                    onPressed: () async {
                      await store.removeHost(host);
                      widget.onRefresh();
                      setState(() {});
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Performance Telemetry Card (logic preserved)
// ─────────────────────────────────────────────────────────────
class PerformanceTelemetryCard extends StatelessWidget with HapticHelper {
  final SettingsProvider settings;
  const PerformanceTelemetryCard({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accentColor = isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan;

    return Consumer<DownloadProvider>(
      builder: (context, provider, child) {
        final activeDownloads = provider.tasks
            .where((t) => t.status == DownloadStatus.downloading)
            .toList();
        final activeThreads = activeDownloads.fold<int>(
          0,
          (sum, t) => sum + t.threadCount,
        );
        final totalSpeedBytes = activeDownloads.fold<double>(
          0.0,
          (sum, t) => sum + t.speed,
        );

        final gpuLoad = settings.classicUi
            ? (isRtl
                ? 'منخفض (نمط الواجهة الكلاسيكي)'
                : 'LOW (Classic UI Mode)')
            : (isRtl
                ? 'متوسط (تأثيرات التوهج والضبابية)'
                : 'MODERATE (Glows & Blurs Active)');

        String batteryImpact;
        Color batteryColor;
        if (settings.batterySaverMode) {
          batteryImpact =
              isRtl ? 'توفير الطاقة نشط (أمثل)' : 'SAVER ACTIVE (Optimal)';
          batteryColor = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
        } else if (activeDownloads.isNotEmpty) {
          batteryImpact =
              isRtl ? 'متوسط (تحميل نشط)' : 'MODERATE (Active downloads)';
          batteryColor = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
        } else {
          batteryImpact = isRtl ? 'منخفض جداً (خامل)' : 'VERY LOW (Idle)';
          batteryColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
        }

        final cachedNodes = provider.tasks.length;
        final cpuLoadValue = activeDownloads.isEmpty
            ? 0.0
            : ((activeThreads * 6).clamp(5, 95) / 100.0);
        final ramLoadValue = (cachedNodes / 100).clamp(0.1, 0.8);

        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _MetricTile(
                      icon: Icons.speed,
                      title: isRtl ? 'السرعة الكلية' : 'Total Net Speed',
                      value: activeDownloads.isEmpty
                          ? '0.0 KB/s'
                          : '${formatBytes(totalSpeedBytes)}/s',
                      accentColor: accentColor,
                      isDark: isDark,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricTile(
                      icon: Icons.dns_outlined,
                      title: isRtl ? 'قنوات الاتصال' : 'Active Connections',
                      value: activeDownloads.isEmpty
                          ? (isRtl ? 'خامل' : 'Idle')
                          : '$activeThreads ${isRtl ? 'خيوط' : 'threads'}',
                      accentColor: accentColor,
                      isDark: isDark,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.2),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accentColor.withValues(alpha: 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    _DiagBar(
                      label: isRtl ? 'حمل المعالج (تقديري)' : 'CPU Load (est.)',
                      value: cpuLoadValue,
                      accentColor: accentColor,
                      isDark: isDark,
                    ),
                    const SizedBox(height: 12),
                    _DiagBar(
                      label: isRtl
                          ? 'استهلاك الذاكرة (تقديري)'
                          : 'RAM Load (est.)',
                      value: ramLoadValue,
                      accentColor: accentColor,
                      isDark: isDark,
                    ),
                    const Divider(height: 16),
                    _DiagRow(
                      label: isRtl
                          ? 'حمل كارت الشاشة (ثابت GPU)'
                          : 'GPU UI Load (Static)',
                      value: gpuLoad,
                      isDark: isDark,
                    ),
                    const Divider(height: 16),
                    _DiagRow(
                      label: isRtl
                          ? 'ملف توفير البطارية (ثابت)'
                          : 'Battery Saver Profile',
                      value: batteryImpact,
                      valueColor: batteryColor,
                      isDark: isDark,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Material(
                color: Colors.transparent,
                child: SwitchListTile(
                  value: settings.batterySaverMode,
                  onChanged: (val) {
                    settings.setBatterySaverMode(val);
                    triggerHaptic(settings);
                  },
                  activeThumbColor: accentColor,
                  activeTrackColor: accentColor.withValues(alpha: 0.3),
                  inactiveThumbColor: isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary,
                  inactiveTrackColor: isDark
                      ? AppTheme.borderSubtle
                      : AppTheme.lightBorderSubtle,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    isRtl ? 'وضع توفير البطارية الأقصى' : 'Battery Saver Mode',
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textPrimary
                          : AppTheme.lightTextPrimary,
                      fontFamily: 'Space Grotesk',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    isRtl
                        ? 'يقيد قنوات الاتصال إلى ٢، والتحميلات المتزامنة إلى ١، ويفرض الواجهة الكلاسيكية لتوفير الطاقة'
                        : 'Limits threads to 2, downloads to 1, and forces Classic UI to save battery',
                    style: TextStyle(
                      color:
                          isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                      fontFamily: 'Space Grotesk',
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Material(
                color: Colors.transparent,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    isRtl
                        ? 'إلغاء تحسين البطارية (استمرار الخلفية)'
                        : 'Ignore Battery Optimization',
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textPrimary
                          : AppTheme.lightTextPrimary,
                      fontFamily: 'Space Grotesk',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    isRtl
                        ? 'السماح للتطبيق بالعمل واستكمال التحميلات في الخلفية دون إيقافه بواسطة النظام'
                        : 'Allow app to continue background downloads without OS termination',
                    style: TextStyle(
                      color:
                          isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                      fontFamily: 'Space Grotesk',
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  trailing: Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 14,
                    color: accentColor,
                  ),
                  onTap: () async {
                    triggerHaptic(settings);
                    final granted = await PermissionService()
                        .requestBatteryOptimizationExemption();
                    if (context.mounted) {
                      ThemedSnackbar.show(
                        context,
                        message: granted
                            ? (isRtl
                                ? 'تم استثناء التطبيق من تحسين البطارية'
                                : 'Battery optimization ignored successfully')
                            : (isRtl
                                ? 'يرجى السماح للتطبيق بالعمل في الخلفية من إعدادات النظام'
                                : 'Battery optimization exemption not granted'),
                        color: granted
                            ? (isDark
                                ? AppTheme.neonGreen
                                : AppTheme.lightNeonGreen)
                            : (isDark
                                ? AppTheme.neonAmber
                                : AppTheme.lightNeonAmber),
                        icon: granted
                            ? Icons.check_circle_rounded
                            : Icons.info_rounded,
                        isDarkMode: isDark,
                      );
                    }
                  },
                ),
              ),
              const SizedBox(height: 10),
              Material(
                color: Colors.transparent,
                child: SwitchListTile(
                  value: settings.reduceVisuals,
                  onChanged: (val) {
                    settings.setReduceVisuals(val);
                    triggerHaptic(settings);
                  },
                  activeThumbColor: accentColor,
                  activeTrackColor: accentColor.withValues(alpha: 0.3),
                  inactiveThumbColor: isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary,
                  inactiveTrackColor: isDark
                      ? AppTheme.borderSubtle
                      : AppTheme.lightBorderSubtle,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    isRtl ? 'تقليل المؤثرات البصرية' : 'REDUCE VISUAL EFFECTS',
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textPrimary
                          : AppTheme.lightTextPrimary,
                      fontFamily: 'Space Grotesk',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    isRtl
                        ? 'إيقاف تأثيرات التوهج والضبابية لتحسين الأداء على الأجهزة الضعيفة'
                        : 'Disable glow and blur effects to improve performance on low-end devices',
                    style: TextStyle(
                      color:
                          isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                      fontFamily: 'Space Grotesk',
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String formatBytes(double bytes) {
    if (bytes <= 0) return '0.0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    while (bytes >= 1024 && i < suffixes.length - 1) {
      bytes /= 1024;
      i++;
    }
    return '${bytes.toStringAsFixed(1)} ${suffixes[i]}';
  }
}

class _MetricTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final bool isDark;
  final Color accentColor;
  const _MetricTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.isDark,
    required this.accentColor,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accentColor.withValues(alpha: 0.2), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: accentColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.textSecondary
                        : AppTheme.lightTextSecondary,
                    fontFamily: 'Space Grotesk',
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
              fontFamily: 'Space Grotesk',
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _DiagBar extends StatelessWidget {
  final String label;
  final double value; // 0.0 to 1.0
  final Color accentColor;
  final bool isDark;

  const _DiagBar({
    required this.label,
    required this.value,
    required this.accentColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                color: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary,
                fontFamily: 'Space Grotesk',
                fontSize: 11,
                fontWeight: FontWeight.w400,
              ),
            ),
            Text(
              '${(value * 100).toInt()}%',
              style: TextStyle(
                color: accentColor,
                fontFamily: 'Space Grotesk',
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: value,
            backgroundColor:
                (isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle)
                    .withValues(alpha: 0.5),
            valueColor: AlwaysStoppedAnimation<Color>(accentColor),
            minHeight: 5,
          ),
        ),
      ],
    );
  }
}

class _DiagRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final bool isDark;
  const _DiagRow({
    required this.label,
    required this.value,
    this.valueColor,
    required this.isDark,
  });
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color:
                isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
            fontFamily: 'Space Grotesk',
            fontSize: 11,
            fontWeight: FontWeight.w400,
          ),
        ),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              color: valueColor ??
                  (isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary),
              fontFamily: 'Space Grotesk',
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

abstract final class _BackupHelper {
  static Future<String?> _showPasswordDialog(
    BuildContext context, {
    required bool isExport,
    required bool isRtl,
    required bool isDark,
  }) async {
    final accentColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          backgroundColor:
              isDark ? AppTheme.surfaceRaised : AppTheme.lightSurfaceRaised,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: accentColor.withValues(alpha: 0.28),
              width: 1.0,
            ),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.lock_outline_rounded,
                  color: accentColor,
                  size: 16,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isExport
                      ? (isRtl ? 'حماية النسخة الاحتياطية' : 'ENCRYPT BACKUP')
                      : (isRtl
                          ? 'فك تشفير النسخة الاحتياطية'
                          : 'DECRYPT BACKUP'),
                  style: TextStyle(
                    color: accentColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 16.0,
                    letterSpacing: 1.1,
                    fontFamily: 'Space Grotesk',
                  ),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isExport
                    ? (isRtl
                        ? 'أدخل كلمة مرور لتشفير ملف النسخ الاحتياطي (اتركه فارغاً للتصدير بدون تشفير):'
                        : 'Enter a password to encrypt the backup file (leave empty to export unencrypted):')
                    : (isRtl
                        ? 'هذا الملف مشفر. يرجى إدخال كلمة المرور لفك التشفير:'
                        : 'This backup file is encrypted. Enter the password to decrypt:'),
                style: TextStyle(
                  color: isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary,
                  fontSize: 14.0,
                  height: 1.45,
                  fontFamily: 'Inter',
                ),
              ),
              const SizedBox(height: 14),
              Container(
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.surface : AppTheme.lightSurface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.24),
                    width: 1,
                  ),
                ),
                child: TextField(
                  controller: controller,
                  obscureText: true,
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.textPrimary
                        : AppTheme.lightTextPrimary,
                    fontSize: 12.5,
                    fontFamily: 'Inter',
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: isRtl ? 'كلمة المرور' : 'Password',
                    hintStyle: TextStyle(
                      color:
                          isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                      fontSize: 12,
                      fontFamily: 'Inter',
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
              ),
              onPressed: () => Navigator.pop(context, null),
              child: Text(
                isRtl ? 'إلغاء' : 'CANCEL',
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'Space Grotesk',
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: accentColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(
                isExport
                    ? (isRtl ? 'تصدير' : 'EXPORT')
                    : (isRtl ? 'فك التشفير' : 'DECRYPT'),
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'Space Grotesk',
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  static Future<bool?> _showImportOptionDialog(
    BuildContext context, {
    required bool isRtl,
    required bool isDark,
  }) async {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            width: 1.0,
          ),
        ),
        title: Text(
          isRtl ? 'خيارات الاستيراد' : 'IMPORT OPTIONS',
          style: TextStyle(
            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            fontWeight: FontWeight.bold,
            fontSize: 16.0,
            letterSpacing: 1.5,
          ),
        ),
        content: Text(
          isRtl
              ? 'كيف ترغب في استيراد سجلات التحميل؟\n• دمج: إضافة السجلات الجديدة والاحتفاظ بالحالية.\n• استبدال: مسح السجلات الحالية بالكامل وتطبيق الجديدة.'
              : 'How would you like to restore the download logs?\n• MERGE: Add new logs and keep existing ones.\n• REPLACE: Wipe all existing logs and apply the new ones.',
          style: TextStyle(
            color:
                isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
            fontSize: 14.0,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: Text(
              isRtl ? 'إلغاء' : 'CANCEL',
              style: TextStyle(
                color: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary,
                fontSize: 13.0,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              isRtl ? 'دمج' : 'MERGE',
              style: TextStyle(
                color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                fontWeight: FontWeight.bold,
                fontSize: 13.0,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              isRtl ? 'استبدال' : 'REPLACE',
              style: TextStyle(
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                fontWeight: FontWeight.bold,
                fontSize: 13.0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static void exportBackup(
      BuildContext context, SettingsProvider settings) async {
    runHaptic(settings);
    final provider = Provider.of<DownloadProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final password = await _showPasswordDialog(
      context,
      isExport: true,
      isRtl: isRtl,
      isDark: isDark,
    );
    if (password == null) return;
    final jsonStr = provider.exportBackupJson(password: password);
    await SharePlus.instance.share(
      ShareParams(text: jsonStr, subject: 'XDM Backup Signal Logs'),
    );
  }

  static void importBackup(
      BuildContext context, SettingsProvider settings) async {
    runHaptic(settings);
    final isDark = settings.isDarkMode;
    final provider = Provider.of<DownloadProvider>(context, listen: false);
    final isRtl = L10n.isRtl(context);
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'txt'],
    );
    if (result == null || result.files.single.path == null) return;
    if (!context.mounted) return;
    final replace = await _showImportOptionDialog(
      context,
      isRtl: isRtl,
      isDark: isDark,
    );
    if (replace == null) return;
    final file = File(result.files.single.path!);
    final fileSize = await file.length();
    const maxSizeBytes = 50 * 1024 * 1024;
    if (fileSize > maxSizeBytes) {
      if (context.mounted) {
        ThemedSnackbar.show(
          context,
          message: isRtl
              ? 'حجم ملف النسخة الاحتياطية كبير جداً (الحد الأقصى 50 ميجابايت)'
              : 'Backup file is too large (maximum 50 MB)',
          color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
          icon: Icons.error_outline,
          isDarkMode: isDark,
        );
      }
      return;
    }
    final jsonStr = await file.readAsString();
    bool isEncrypted = false;
    try {
      final bytes = base64Decode(jsonStr.trim());
      final magic = utf8.encode('XDMCRYPT');
      if (bytes.length >= magic.length) {
        isEncrypted = true;
        for (int i = 0; i < magic.length; i++) {
          if (bytes[i] != magic[i]) {
            isEncrypted = false;
            break;
          }
        }
      }
    } catch (e, st) {
      Logger('settings_screen')
          .warning('[settings_screen] operation failed', e, st);
    }
    String? password = '';
    if (isEncrypted) {
      if (!context.mounted) return;
      password = await _showPasswordDialog(
        context,
        isExport: false,
        isRtl: isRtl,
        isDark: isDark,
      );
      if (password == null) return;
    }
    final success = await provider.importBackupJson(
      jsonStr,
      replace: replace,
      password: password,
    );
    if (!context.mounted) return;
    ThemedSnackbar.show(
      context,
      message: success
          ? (isRtl
              ? 'تم استيراد النسخة الاحتياطية بنجاح'
              : 'Backup imported successfully')
          : (isRtl
              ? 'فشل استيراد النسخة الاحتياطية (تأكد من صحة كلمة المرور)'
              : 'Failed to import backup (check password)'),
      color: success
          ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
          : (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed),
      icon: success ? Icons.check_circle_outline : Icons.error_outline,
      isDarkMode: isDark,
    );
  }
}
