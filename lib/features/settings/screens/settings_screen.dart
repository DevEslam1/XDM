import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
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
import '../../downloads/provider/download_provider.dart';
import '../../downloads/models/download_task.dart';
import '../../browser/services/ad_blocker.dart';
import '../provider/settings_provider.dart';
import '../widgets/update_dialogs.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with HapticHelper, TickerProviderStateMixin {
  late final TextEditingController _uaController;
  late final TextEditingController _proxyHostController;
  late final TextEditingController _proxyPortController;
  late final TextEditingController _proxyUsernameController;
  late final TextEditingController _proxyPasswordController;
  late final TextEditingController _backendUrlController;
  bool _isUpdatingHosts = false;
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
    _reveal = AnimationController(vsync: this, duration: AppTheme.motionReveal)
      ..forward();
  }

  @override
  void dispose() {
    _uaController.dispose();
    _proxyHostController.dispose();
    _proxyPortController.dispose();
    _proxyUsernameController.dispose();
    _proxyPasswordController.dispose();
    _backendUrlController.dispose();
    _reveal.dispose();
    super.dispose();
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

  // ── Backup password dialog ──
  Future<String?> _showPasswordDialog(
    BuildContext context, {
    required bool isExport,
    required bool isRtl,
    required bool isDark,
  }) async {
    final accentColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
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
          backgroundColor: isDark
              ? AppTheme.surfaceRaised
              : AppTheme.lightSurfaceRaised,
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
                    color: textClr,
                    fontSize: 12.5,
                    fontFamily: 'Inter',
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: isRtl ? 'كلمة المرور' : 'Password',
                    hintStyle: TextStyle(
                      color: isDark
                          ? AppTheme.textMuted
                          : AppTheme.lightTextMuted,
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

  Future<bool?> _showImportOptionDialog(
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
            color: isDark
                ? AppTheme.textSecondary
                : AppTheme.lightTextSecondary,
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

  void _exportBackup(BuildContext context, SettingsProvider settings) async {
    triggerHaptic(settings);
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

  void _importBackup(BuildContext context, SettingsProvider settings) async {
    triggerHaptic(settings);
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
    } catch (_) {}
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

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isRtl = L10n.isRtl(context);
    final isDark = settings.isDarkMode;
    final classicUi = settings.classicUi;

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
                  const SizedBox(height: 16),
                  _stagger(
                    0.08,
                    _ConsoleSection(
                      index: '01',
                      title: L10n.of(context, 'settings_engine_status'),
                      accentColor: isDark
                          ? AppTheme.neonBlue
                          : AppTheme.lightNeonBlue,
                      isDark: isDark,
                      isExpanded:
                          _expandedSections[L10n.of(
                            context,
                            'settings_engine_status',
                          )] ??
                          true,
                      onToggle: () {
                        triggerHaptic(settings);
                        setState(() {
                          final k = L10n.of(context, 'settings_engine_status');
                          _expandedSections[k] =
                              !(_expandedSections[k] ?? true);
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
                              : L10n.of(context, 'settings_max_channels_sub'),
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
                          title: L10n.of(context, 'settings_default_threads'),
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
                          subtitle:
                              settings.customDownloadPath?.isNotEmpty == true
                              ? settings.customDownloadPath!
                              : (isRtl
                                    ? 'تلقائي (Downloads/XDM)'
                                    : 'Default (Downloads/XDM)'),
                          onTap: () async {
                            triggerHaptic(settings);
                            final path = await FilePicker.getDirectoryPath();
                            if (path != null) {
                              await settings.setCustomDownloadPath(path);
                            }
                          },
                          onClear:
                              settings.customDownloadPath?.isNotEmpty == true
                              ? () async {
                                  triggerHaptic(settings);
                                  await settings.setCustomDownloadPath(null);
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
                      isExpanded:
                          _expandedSections[L10n.of(
                            context,
                            'settings_bandwidth',
                          )] ??
                          false,
                      onToggle: () {
                        triggerHaptic(settings);
                        setState(() {
                          final k = L10n.of(context, 'settings_bandwidth');
                          _expandedSections[k] =
                              !(_expandedSections[k] ?? false);
                        });
                      },
                      children: [
                        _SliderTile(
                          accentColor: isDark
                              ? AppTheme.neonGreen
                              : AppTheme.lightNeonGreen,
                          title: L10n.of(context, 'settings_speed_limit'),
                          subtitle: settings.speedLimitMb == 0.0
                              ? L10n.of(context, 'settings_unlimited')
                              : '${settings.speedLimitMb.toInt()} ${L10n.of(context, 'settings_limit_to')}',
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
                          subtitle: L10n.of(context, 'settings_wifi_only_sub'),
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
                          subtitle: L10n.of(context, 'settings_auto_retry_sub'),
                          value: settings.autoRetryEnabled,
                          onChanged: (val) {
                            settings.setAutoRetryEnabled(val);
                            triggerHaptic(settings);
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
                      isExpanded:
                          _expandedSections[L10n.of(
                            context,
                            'settings_cockpit',
                          )] ??
                          false,
                      onToggle: () {
                        triggerHaptic(settings);
                        setState(() {
                          final k = L10n.of(context, 'settings_cockpit');
                          _expandedSections[k] =
                              !(_expandedSections[k] ?? false);
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
                          subtitle:
                              '${settings.gridOpacity.toInt()}% ${L10n.of(context, 'settings_grid_sub')}',
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
                      isExpanded:
                          _expandedSections[L10n.of(
                            context,
                            'settings_alerters',
                          )] ??
                          false,
                      onToggle: () {
                        triggerHaptic(settings);
                        setState(() {
                          final k = L10n.of(context, 'settings_alerters');
                          _expandedSections[k] =
                              !(_expandedSections[k] ?? false);
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
                              ? AppTheme.neonAmber
                              : AppTheme.lightNeonAmber,
                          title: L10n.of(context, 'settings_haptic'),
                          subtitle: L10n.of(context, 'settings_haptic_sub'),
                          value: settings.vibration,
                          onChanged: (val) {
                            settings.setVibration(val);
                            if (val) HapticFeedback.lightImpact();
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
                      accentColor: isDark
                          ? AppTheme.neonCyan
                          : AppTheme.lightNeonCyan,
                      isDark: isDark,
                      isExpanded:
                          _expandedSections[L10n.isRtl(context)
                              ? 'مراقب الأداء والتحكم بالنظام'
                              : 'TELEMETRY & PERFORMANCE'] ??
                          false,
                      onToggle: () {
                        triggerHaptic(settings);
                        setState(() {
                          final k = L10n.isRtl(context)
                              ? 'مراقب الأداء والتحكم بالنظام'
                              : 'TELEMETRY & PERFORMANCE';
                          _expandedSections[k] =
                              !(_expandedSections[k] ?? false);
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
                      accentColor: isDark
                          ? AppTheme.neonRed
                          : AppTheme.lightNeonRed,
                      isDark: isDark,
                      isExpanded:
                          _expandedSections[L10n.of(
                            context,
                            'settings_youtube_backend',
                          )] ??
                          false,
                      onToggle: () {
                        triggerHaptic(settings);
                        setState(() {
                          final k = L10n.of(
                            context,
                            'settings_youtube_backend',
                          );
                          _expandedSections[k] =
                              !(_expandedSections[k] ?? false);
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
                          onSubmitted: (val) =>
                              settings.setBackendUrl(val.trim()),
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
                                final response = await XdmBackendClient()
                                    .health();
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
                      isExpanded:
                          _expandedSections[L10n.of(
                            context,
                            'settings_adv_console',
                          )] ??
                          false,
                      onToggle: () {
                        triggerHaptic(settings);
                        setState(() {
                          final k = L10n.of(context, 'settings_adv_console');
                          _expandedSections[k] =
                              !(_expandedSections[k] ?? false);
                        });
                      },
                      children: [
                        _SwitchTile(
                          accentColor: isDark
                              ? AppTheme.neonBlue
                              : AppTheme.lightNeonBlue,
                          title: L10n.of(context, 'settings_subfolders'),
                          subtitle: L10n.of(context, 'settings_subfolders_sub'),
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
                        _UpdateHostsTile(
                          accentColor: isDark
                              ? AppTheme.neonBlue
                              : AppTheme.lightNeonBlue,
                          isUpdating: _isUpdatingHosts,
                          onRefresh: () async {
                            triggerHaptic(settings);
                            setState(() => _isUpdatingHosts = true);
                            ThemedSnackbar.show(
                              context,
                              message: L10n.isRtl(context)
                                  ? 'جاري تنزيل وتحديث فلاتر حجب الإعلانات...'
                                  : 'Updating adblocker filters...',
                              color: isDark
                                  ? AppTheme.neonBlue
                                  : AppTheme.lightNeonBlue,
                              icon: Icons.downloading,
                              isDarkMode: isDark,
                            );
                            try {
                              await AdBlocker.updateHosts();
                              if (context.mounted) {
                                ThemedSnackbar.show(
                                  context,
                                  message: L10n.isRtl(context)
                                      ? 'تم تحديث فلاتر منع الإعلانات بنجاح!'
                                      : 'Adblocker filters updated!',
                                  color: isDark
                                      ? AppTheme.neonGreen
                                      : AppTheme.lightNeonGreen,
                                  icon: Icons.check_circle_outline,
                                  isDarkMode: isDark,
                                );
                              }
                            } catch (e) {
                              if (context.mounted) {
                                ThemedSnackbar.show(
                                  context,
                                  message: L10n.isRtl(context)
                                      ? 'فشل تحديث فلاتر منع الإعلانات'
                                      : 'Failed to update filters',
                                  color: isDark
                                      ? AppTheme.neonRed
                                      : AppTheme.lightNeonRed,
                                  icon: Icons.error_outline,
                                  isDarkMode: isDark,
                                );
                              }
                            } finally {
                              if (mounted) {
                                setState(() => _isUpdatingHosts = false);
                              }
                            }
                          },
                        ),
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
                                _uaController.text = settings.customUserAgent;
                                _proxyHostController.text = settings.proxyHost;
                                _proxyPortController.text = settings.proxyPort
                                    .toString();
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
                  _stagger(0.64, _BackupModule(settings: settings)),
                  const SizedBox(height: 14),
                  _stagger(0.72, _CommsModule(settings: settings)),
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
                    color: isDark
                        ? AppTheme.textMuted
                        : AppTheme.lightTextMuted,
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
            inactiveThumbColor: isDark
                ? AppTheme.textSecondary
                : AppTheme.lightTextSecondary,
            inactiveTrackColor: isDark
                ? AppTheme.borderSubtle
                : AppTheme.lightBorderSubtle,
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
                color: isDark
                    ? AppTheme.textPrimary
                    : AppTheme.lightTextPrimary,
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
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final Color accentColor; // NEW

  const _SliderTile({
    required this.title,
    required this.subtitle,
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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                    subtitle,
                    style: TextStyle(
                      color: accentColor,
                      fontFamily: 'Space Grotesk',
                      fontSize: 12.0,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: accentColor,
                inactiveTrackColor: isDark
                    ? AppTheme.borderSubtle
                    : AppTheme.lightBorderSubtle,
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
                  dropdownColor: isDark
                      ? AppTheme.surface
                      : AppTheme.lightSurface,
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
  final ValueChanged<String>? onSubmitted;
  final Color accentColor;

  const _TextFieldTile({
    required this.title,
    required this.subtitle,
    required this.controller,
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
                      color: isDark
                          ? AppTheme.textMuted
                          : AppTheme.lightTextMuted,
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
                color: isDark
                    ? AppTheme.textPrimary
                    : AppTheme.lightTextPrimary,
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

class _UpdateHostsTile extends StatelessWidget {
  final bool isUpdating;
  final VoidCallback onRefresh;
  final Color accentColor; // NEW
  const _UpdateHostsTile({
    required this.isUpdating,
    required this.onRefresh,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
                    L10n.isRtl(context)
                        ? 'تحديث فلاتر الحجب'
                        : 'UPDATE ADBLOCKER FILTERS',
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textPrimary
                          : AppTheme.lightTextPrimary,
                      fontFamily: 'Space Grotesk',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    L10n.isRtl(context)
                        ? 'تحديث يدوي لقوائم حجب الإعلانات والتعقب'
                        : 'Manually update ad & tracker blocklists',
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textMuted
                          : AppTheme.lightTextMuted,
                      fontFamily: 'Inter',
                      fontSize: 11.5,
                      height: 1.35,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            isUpdating
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                    ),
                  )
                : GestureDetector(
                    onTap: onRefresh,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: accentColor.withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.sync, color: accentColor, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            L10n.isRtl(context) ? 'تحديث' : 'UPDATE',
                            style: TextStyle(
                              color: accentColor,
                              fontFamily: 'Space Grotesk',
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ],
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

    final state = _SettingsScreenState();

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
                  color: isDark
                      ? AppTheme.textPrimary
                      : AppTheme.lightTextPrimary,
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
                  onPressed: () => state._exportBackup(context, settings),
                  text: L10n.of(context, 'settings_export'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: NeonGlowButton(
                  isFilled: true,
                  color: violetClr,
                  onPressed: () => state._importBackup(context, settings),
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
                  color: isDark
                      ? AppTheme.textPrimary
                      : AppTheme.lightTextPrimary,
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
                    color: isDark
                        ? AppTheme.neonGreen
                        : AppTheme.lightNeonGreen,
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
                      color: isDark
                          ? AppTheme.textMuted
                          : AppTheme.lightTextMuted,
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
          batteryImpact = isRtl
              ? 'توفير الطاقة نشط (أمثل)'
              : 'SAVER ACTIVE (Optimal)';
          batteryColor = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
        } else if (activeDownloads.isNotEmpty) {
          batteryImpact = isRtl
              ? 'متوسط (تحميل نشط)'
              : 'MODERATE (Active downloads)';
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
                      color: isDark
                          ? AppTheme.textMuted
                          : AppTheme.lightTextMuted,
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
                      color: isDark
                          ? AppTheme.textMuted
                          : AppTheme.lightTextMuted,
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
                      color: isDark
                          ? AppTheme.textMuted
                          : AppTheme.lightTextMuted,
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
            color: isDark
                ? AppTheme.textSecondary
                : AppTheme.lightTextSecondary,
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
              color:
                  valueColor ??
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
