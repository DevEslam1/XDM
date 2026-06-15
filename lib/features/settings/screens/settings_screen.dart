import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/dmx_app_icon.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/models/download_task.dart';
import '../provider/settings_provider.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../browser/services/ad_blocker.dart';
import '../../../core/utils/constants.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with HapticHelper {
  late final TextEditingController _uaController;
  late final TextEditingController _proxyController;
  late final TextEditingController _proxyHostController;
  late final TextEditingController _proxyPortController;
  late final TextEditingController _proxyUsernameController;
  late final TextEditingController _proxyPasswordController;
  bool _isUpdatingHosts = false;

  @override
  void initState() {
    super.initState();
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    _uaController = TextEditingController(text: settings.customUserAgent);
    _proxyController = TextEditingController(text: settings.proxyAddress);
    _proxyHostController = TextEditingController(text: settings.proxyHost);
    _proxyPortController = TextEditingController(text: settings.proxyPort.toString());
    _proxyUsernameController = TextEditingController(text: settings.proxyUsername);
    _proxyPasswordController = TextEditingController(text: settings.proxyPassword);
  }

  @override
  void dispose() {
    _uaController.dispose();
    _proxyController.dispose();
    _proxyHostController.dispose();
    _proxyPortController.dispose();
    _proxyUsernameController.dispose();
    _proxyPasswordController.dispose();
    super.dispose();
  }

  Future<String?> _showPasswordDialog(BuildContext context, {required bool isExport, required bool isRtl, required bool isDark}) async {
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          title: Text(
            isExport
                ? (isRtl ? 'حماية النسخة الاحتياطية' : 'ENCRYPT BACKUP')
                : (isRtl ? 'فك تشفير النسخة الاحتياطية' : 'DECRYPT BACKUP'),
            style: TextStyle(
              color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
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
                style: TextStyle(color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary, fontSize: 11),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F0F16) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isDark ? const Color(0x15FFFFFF) : const Color(0x0D000000),
                    width: 0.8,
                  ),
                ),
                child: TextField(
                  controller: controller,
                  obscureText: true,
                  style: TextStyle(color: textClr, fontSize: 12),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: isRtl ? 'كلمة المرور' : 'Password',
                    hintStyle: TextStyle(color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted, fontSize: 12),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: Text(isRtl ? 'إلغاء' : 'CANCEL', style: TextStyle(color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary, fontSize: 12)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(
                isExport
                    ? (isRtl ? 'تصدير' : 'EXPORT')
                    : (isRtl ? 'فك التشفير' : 'DECRYPT'),
                style: TextStyle(
                  color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<bool?> _showImportOptionDialog(BuildContext context, {required bool isRtl, required bool isDark}) async {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          title: Text(
            isRtl ? 'خيارات الاستيراد' : 'IMPORT OPTIONS',
            style: TextStyle(
              color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          content: Text(
            isRtl
                ? 'كيف ترغب في استيراد سجلات التحميل؟\n\n• دمج: إضافة السجلات الجديدة والاحتفاظ بالحالية.\n• استبدال: مسح السجلات الحالية بالكامل وتطبيق الجديدة.'
                : 'How would you like to restore the download logs?\n\n• MERGE: Add new logs and keep existing ones.\n• REPLACE: Wipe all existing logs and apply the new ones.',
            style: TextStyle(color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary, fontSize: 11, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: Text(isRtl ? 'إلغاء' : 'CANCEL', style: TextStyle(color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary, fontSize: 12)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false), // merge
              child: Text(
                isRtl ? 'دمج' : 'MERGE',
                style: TextStyle(
                  color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true), // replace
              child: Text(
                isRtl ? 'استبدال' : 'REPLACE',
                style: TextStyle(
                  color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _exportBackup(BuildContext context, SettingsProvider settings) async {
    triggerHaptic(settings);
    final provider = Provider.of<DownloadProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

    // Prompt for password
    final password = await _showPasswordDialog(context, isExport: true, isRtl: isRtl, isDark: isDark);
    // If they closed dialog (returned null), cancel the export
    if (password == null) return;

    final jsonStr = provider.exportBackupJson(password: password);
    await Share.share(jsonStr, subject: 'XDM Backup Signal Logs');
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

    // Ask for Merge vs Replace
    final replace = await _showImportOptionDialog(context, isRtl: isRtl, isDark: isDark);
    if (replace == null) return; // User cancelled

    final file = File(result.files.single.path!);
    final jsonStr = await file.readAsString();

    // Detect if encrypted
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
      password = await _showPasswordDialog(context, isExport: false, isRtl: isRtl, isDark: isDark);
      if (password == null) return; // User cancelled password dialog
    }

    final success = await provider.importBackupJson(jsonStr, replace: replace, password: password);
    if (!context.mounted) return;
    ThemedSnackbar.show(
      context,
      message: success
          ? (isRtl ? 'تم استيراد النسخة الاحتياطية بنجاح' : 'Backup imported successfully')
          : (isRtl ? 'فشل استيراد النسخة الاحتياطية (تأكد من صحة كلمة المرور)' : 'Failed to import backup (check password)'),
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
    final isDark = settings.isDarkMode;
    final dividerColor = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: settings.classicUi
              ? (isDark ? AppTheme.surface : AppTheme.lightSurface)
              : Colors.transparent,
          elevation: 0,
          shape: settings.classicUi
              ? Border(
                  bottom: BorderSide(
                    color: isDark ? AppTheme.border : AppTheme.lightBorder,
                    width: 1.0,
                  ),
                )
              : null,
          flexibleSpace: settings.classicUi
              ? null
              : ClipRect(
                  child: DmxBackdropFilter(
                    sigmaX: 12,
                    sigmaY: 12,
                    child: Container(
                      color: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.5),
                    ),
                  ),
                ),
          title: Text(
            L10n.of(context, 'config_header'),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              fontSize: 16,
            ),
          ),
          automaticallyImplyLeading: false,
        ),
        body: Directionality(
          textDirection: L10n.isRtl(context) ? TextDirection.rtl : TextDirection.ltr,
          child: SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // About / Branding header panel
                  _buildBrandingPanel(context, settings),
                  const SizedBox(height: 20),

                  // 1. General Settings Group
                  _buildSettingsSection(
                    context,
                    settings: settings,
                    title: L10n.of(context, 'settings_engine_status'),
                    children: [
                      _buildSwitchTile(
                        settings: settings,
                        title: L10n.of(context, 'settings_auto_resume'),
                        subtitle: L10n.of(context, 'settings_auto_resume_sub'),
                        value: settings.autoStart,
                        onChanged: (val) {
                          settings.setAutoStart(val);
                          triggerHaptic(settings);
                        },
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildDropdownTile<int>(
                        settings: settings,
                        title: L10n.of(context, 'settings_max_channels'),
                        subtitle: L10n.of(context, 'settings_max_channels_sub'),
                        value: settings.maxDownloads,
                        items: [1, 2, 3, 5, 8],
                        onChanged: (val) {
                          if (val != null) {
                            settings.setMaxDownloads(val);
                            triggerHaptic(settings);
                          }
                        },
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildDropdownTile<int>(
                        settings: settings,
                        title: L10n.of(context, 'settings_default_threads'),
                        subtitle: L10n.of(context, 'settings_default_threads_sub'),
                        value: settings.defaultThreadCount,
                        items: kAvailableThreadOptions,
                        onChanged: (val) {
                          if (val != null) {
                            settings.setDefaultThreadCount(val);
                            triggerHaptic(settings);
                          }
                        },
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildDropdownTile<String>(
                        settings: settings,
                        title: L10n.of(context, 'settings_lang'),
                        subtitle: L10n.of(context, 'settings_lang_sub'),
                        value: settings.languageCode,
                        items: ['en', 'ar'],
                        itemLabels: {
                          'en': 'ENGLISH',
                          'ar': 'العربية',
                        },
                        onChanged: (val) {
                          if (val != null) {
                            settings.setLanguageCode(val);
                            triggerHaptic(settings);
                          }
                        },
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildPathPickerTile(
                        context,
                        settings: settings,
                        title: L10n.isRtl(context) ? 'مجلد التحميل الافتراضي' : 'Default Download Folder',
                        subtitle: settings.customDownloadPath?.isNotEmpty == true
                            ? settings.customDownloadPath!
                            : (L10n.isRtl(context) ? 'تلقائي (Downloads/XDM)' : 'Default (Downloads/XDM)'),
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
                    ],
                  ),
                  const SizedBox(height: 16),

                  // 2. Connection Settings Group
                  _buildSettingsSection(
                    context,
                    settings: settings,
                    title: L10n.of(context, 'settings_bandwidth'),
                    children: [
                      _buildSliderTile(
                        settings: settings,
                        title: L10n.of(context, 'settings_speed_limit'),
                        subtitle: settings.speedLimitMb == 0.0
                            ? L10n.of(context, 'settings_unlimited')
                            : '${settings.speedLimitMb.toInt()} ${L10n.of(context, 'settings_limit_to')}',
                        value: settings.speedLimitMb,
                        min: 0.0,
                        max: 100.0,
                        divisions: 10,
                        onChanged: (val) {
                          settings.setSpeedLimit(val);
                        },
                        onChangeEnd: (val) {
                          triggerHaptic(settings);
                        },
                      ),
                      _buildSwitchTile(
                        settings: settings,
                        title: L10n.of(context, 'settings_wifi_only'),
                        subtitle: L10n.of(context, 'settings_wifi_only_sub'),
                        value: settings.wifiOnly,
                        onChanged: (val) {
                          settings.setWifiOnly(val);
                          triggerHaptic(settings);
                        },
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildSwitchTile(
                        settings: settings,
                        title: L10n.isRtl(context) ? 'تفعيل مشاركة التورنت (Seeding)' : 'Torrent Seeding',
                        subtitle: L10n.isRtl(context) ? 'مشاركة أجزاء الملفات بعد اكتمال التحميل' : 'Share files back to peers after download completes',
                        value: settings.globalTorrentSeeding,
                        onChanged: (val) {
                          settings.setGlobalTorrentSeeding(val);
                          triggerHaptic(settings);
                        },
                      ),
                      if (settings.globalTorrentSeeding) ...[
                        Divider(color: dividerColor, height: 1),
                        _buildSwitchTile(
                          settings: settings,
                          title: L10n.isRtl(context) ? 'تقييد سرعة المشاركة' : 'Limit Seeding Speed',
                          subtitle: L10n.isRtl(context) ? 'تحديد حد أقصى لسرعة الرفع' : 'Set a maximum limit for upload speed',
                          value: settings.globalTorrentSeedingLimited,
                          onChanged: (val) {
                            settings.setGlobalTorrentSeedingLimited(val);
                            triggerHaptic(settings);
                          },
                        ),
                        if (settings.globalTorrentSeedingLimited) ...[
                          Divider(color: dividerColor, height: 1),
                          _buildSliderTile(
                            settings: settings,
                            title: L10n.isRtl(context) ? 'سرعة الرفع القصوى' : 'Maximum Upload Speed',
                            subtitle: '${settings.globalTorrentSeedingLimitKbps} kbps (${(settings.globalTorrentSeedingLimitKbps / 8).toStringAsFixed(1)} KB/s)',
                            value: settings.globalTorrentSeedingLimitKbps.toDouble(),
                            min: 100.0,
                            max: 10000.0,
                            divisions: 99,
                            onChanged: (val) {
                              settings.setGlobalTorrentSeedingLimitKbps(val.round());
                            },
                            onChangeEnd: (val) {
                              triggerHaptic(settings);
                            },
                          ),
                        ],
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),

                  // 3. UI Interface Settings Group
                  _buildSettingsSection(
                    context,
                    settings: settings,
                    title: L10n.of(context, 'settings_cockpit'),
                    children: [
                      _buildDropdownTile<String>(
                        settings: settings,
                        title: L10n.isRtl(context) ? 'سمة المظهر' : 'THEME MODE',
                        subtitle: L10n.isRtl(context) ? 'اختر سمة مظهر التطبيق' : 'Select application theme mode',
                        value: settings.themeMode,
                        items: const ['light', 'dark', 'system'],
                        itemLabels: {
                          'light': L10n.isRtl(context) ? 'فاتح' : 'LIGHT',
                          'dark': L10n.isRtl(context) ? 'داكن' : 'DARK',
                          'system': L10n.isRtl(context) ? 'تلقائي' : 'SYSTEM DEFAULT',
                        },
                        onChanged: (val) {
                          if (val != null) {
                            settings.setThemeMode(val);
                            triggerHaptic(settings);
                          }
                        },
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildSwitchTile(
                        settings: settings,
                        title: L10n.of(context, 'settings_classic_ui'),
                        subtitle: L10n.of(context, 'settings_classic_ui_sub'),
                        value: settings.classicUi,
                        onChanged: (val) {
                          settings.setClassicUi(val);
                          triggerHaptic(settings);
                        },
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildSwitchTile(
                        settings: settings,
                        title: L10n.of(context, 'settings_glow'),
                        subtitle: L10n.of(context, 'settings_glow_sub'),
                        value: settings.enableGlow,
                        onChanged: (val) {
                          settings.setEnableGlow(val);
                          triggerHaptic(settings);
                        },
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildSliderTile(
                        settings: settings,
                        title: L10n.of(context, 'settings_grid'),
                        subtitle: '${settings.gridOpacity.toInt()}% ${L10n.of(context, 'settings_grid_sub')}',
                        value: settings.gridOpacity,
                        min: 0.0,
                        max: 40.0,
                        divisions: 8,
                        onChanged: (val) {
                          settings.setGridOpacity(val);
                        },
                        onChangeEnd: (val) {
                          triggerHaptic(settings);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // 4. Notifications Group
                  _buildSettingsSection(
                    context,
                    settings: settings,
                    title: L10n.of(context, 'settings_alerters'),
                    children: [
                      _buildSwitchTile(
                        settings: settings,
                        title: L10n.isRtl(context) ? 'الإشعارات العامة' : 'GLOBAL NOTIFICATIONS',
                        subtitle: L10n.isRtl(context) ? 'تفعيل أو تعطيل جميع إشعارات التطبيق' : 'Enable or disable all app notifications',
                        value: settings.notificationsEnabled,
                        onChanged: (val) {
                          settings.setNotificationsEnabled(val);
                          triggerHaptic(settings);
                        },
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildSwitchTile(
                        settings: settings,
                        title: L10n.of(context, 'settings_chime'),
                        subtitle: L10n.of(context, 'settings_chime_sub'),
                        value: settings.soundNotification,
                        onChanged: (val) {
                          settings.setSoundNotification(val);
                          triggerHaptic(settings);
                        },
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildSwitchTile(
                        settings: settings,
                        title: L10n.of(context, 'settings_haptic'),
                        subtitle: L10n.of(context, 'settings_haptic_sub'),
                        value: settings.vibration,
                        onChanged: (val) {
                          settings.setVibration(val);
                          HapticFeedback.lightImpact();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // System Telemetry & Performance Governor
                  _buildSettingsSection(
                    context,
                    settings: settings,
                    title: L10n.isRtl(context) ? 'مراقب الأداء والتحكم بالنظام' : 'TELEMETRY & PERFORMANCE GOVERNOR',
                    children: [
                      PerformanceTelemetryCard(settings: settings),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // 5. ADVANCED POWER CONSOLE
                  _buildSettingsSection(
                    context,
                    settings: settings,
                    title: L10n.of(context, 'settings_adv_console'),
                    children: [
                      _buildSwitchTile(
                        settings: settings,
                        title: L10n.isRtl(context) ? 'حفظ سجل المتصفح' : 'Save Browser History',
                        subtitle: L10n.isRtl(context) ? 'حفظ المواقع التي تزورها في السجل' : 'Keep a history of websites you visit',
                        value: settings.saveBrowserHistory,
                        onChanged: (val) {
                          settings.setSaveBrowserHistory(val);
                          triggerHaptic(settings);
                        },
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildSwitchTile(
                        settings: settings,
                        title: L10n.of(context, 'settings_biometric'),
                        subtitle: L10n.of(context, 'settings_biometric_sub'),
                        value: settings.biometricLock,
                        onChanged: (val) {
                          settings.setBiometricLock(val);
                          triggerHaptic(settings);
                        },
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildSwitchTile(
                        settings: settings,
                        title: L10n.of(context, 'settings_subfolders'),
                        subtitle: L10n.of(context, 'settings_subfolders_sub'),
                        value: settings.categoryFolders,
                        onChanged: (val) {
                          settings.setCategoryFolders(val);
                          triggerHaptic(settings);
                        },
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildDropdownTile<int>(
                        settings: settings,
                        title: L10n.of(context, 'settings_cleanup'),
                        subtitle: L10n.of(context, 'settings_cleanup_sub'),
                        value: settings.cleanupDays,
                        items: [0, 7, 30],
                        itemLabels: {
                          0: L10n.isRtl(context) ? 'أبداً' : 'NEVER',
                          7: L10n.isRtl(context) ? '٧ أيام' : '7 DAYS',
                          30: L10n.isRtl(context) ? '٣٠ يوماً' : '30 DAYS',
                        },
                        onChanged: (val) {
                          if (val != null) {
                            settings.setCleanupDays(val);
                            triggerHaptic(settings);
                          }
                        },
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildTextFieldTile(
                        title: L10n.of(context, 'settings_ua'),
                        subtitle: L10n.of(context, 'settings_ua_sub'),
                        controller: _uaController,
                        onChanged: (val) {
                          settings.setCustomUserAgent(val);
                        },
                        isDark: isDark,
                      ),
                      Divider(color: dividerColor, height: 1),
                      _buildSwitchTile(
                        settings: settings,
                        title: L10n.of(context, 'settings_proxy'),
                        subtitle: L10n.of(context, 'settings_proxy_sub'),
                        value: settings.enableProxy,
                        onChanged: (val) {
                          settings.setEnableProxy(val);
                          triggerHaptic(settings);
                        },
                      ),
                      if (settings.enableProxy) ...[
                        Divider(color: dividerColor, height: 1),
                        _buildTextFieldTile(
                          title: isRtl ? 'عنوان الوكيل (Host)' : 'PROXY HOST',
                          subtitle: isRtl ? 'اسم المضيف أو عنوان IP' : 'Host name or IP address',
                          controller: _proxyHostController,
                          onChanged: (val) {
                            settings.setProxyHost(val.trim());
                            settings.setProxyAddress('${val.trim()}:${settings.proxyPort}');
                          },
                          isDark: isDark,
                        ),
                        Divider(color: dividerColor, height: 1),
                        _buildTextFieldTile(
                          title: isRtl ? 'منفذ الوكيل (Port)' : 'PROXY PORT',
                          subtitle: isRtl ? 'منفذ الاتصال بالوكيل' : 'Port number for connection',
                          controller: _proxyPortController,
                          onChanged: (val) {
                            final port = int.tryParse(val.trim()) ?? 8080;
                            settings.setProxyPort(port);
                            settings.setProxyAddress('${settings.proxyHost}:$port');
                          },
                          isDark: isDark,
                        ),
                        Divider(color: dividerColor, height: 1),
                        _buildTextFieldTile(
                          title: isRtl ? 'اسم المستخدم (اختياري)' : 'PROXY USERNAME (OPTIONAL)',
                          subtitle: isRtl ? 'اسم المستخدم لمصادقة الوكيل' : 'Username for proxy credentials',
                          controller: _proxyUsernameController,
                          onChanged: (val) {
                            settings.setProxyUsername(val.trim());
                          },
                          isDark: isDark,
                        ),
                        Divider(color: dividerColor, height: 1),
                        _buildTextFieldTile(
                          title: isRtl ? 'كلمة المرور (اختياري)' : 'PROXY PASSWORD (OPTIONAL)',
                          subtitle: isRtl ? 'كلمة المرور لمصادقة الوكيل' : 'Password for proxy credentials',
                          controller: _proxyPasswordController,
                          onChanged: (val) {
                            settings.setProxyPassword(val.trim());
                          },
                          isDark: isDark,
                        ),
                        Divider(color: dividerColor, height: 1),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
                          child: NeonGlowButton(
                            isFilled: false,
                            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                            text: isRtl ? 'اختبار الاتصال' : 'TEST CONNECTION',
                            onPressed: () async {
                              triggerHaptic(settings);
                              ThemedSnackbar.show(
                                context,
                                message: isRtl ? 'جاري اختبار اتصال الوكيل...' : 'Testing proxy connection...',
                                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                                icon: Icons.sync,
                                isDarkMode: isDark,
                              );
                              final success = await settings.testProxyConnection(
                                _proxyHostController.text.trim(),
                                int.tryParse(_proxyPortController.text.trim()) ?? 8080,
                                _proxyUsernameController.text.trim(),
                                _proxyPasswordController.text.trim(),
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                ThemedSnackbar.show(
                                  context,
                                  message: success
                                      ? (isRtl ? 'نجح الاتصال بالوكيل!' : 'Proxy connection successful!')
                                      : (isRtl ? 'فشل الاتصال بالوكيل' : 'Proxy connection failed'),
                                  color: success
                                      ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
                                      : (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed),
                                  icon: success ? Icons.check_circle_outline : Icons.error_outline,
                                  isDarkMode: isDark,
                                );
                              }
                            },
                          ),
                        ),
                        Divider(color: dividerColor, height: 1),
                        _buildSwitchTile(
                          settings: settings,
                          title: L10n.of(context, 'settings_bypass_ssl'),
                          subtitle: L10n.of(context, 'settings_bypass_ssl_sub'),
                          value: settings.bypassSSL,
                          onChanged: (val) async {
                            if (val) {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (context) {
                                  return AlertDialog(
                                    backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
                                    title: Text(
                                      isRtl ? 'تحذير أمني' : 'SECURITY WARNING',
                                      style: TextStyle(
                                        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    content: Text(
                                      isRtl
                                          ? 'تخطي التحقق من شهادة SSL يعرض اتصالاتك لخطر التنصت وهجمات رجل في المنتصف (MITM). هل تريد الاستمرار؟'
                                          : 'Bypassing SSL verification exposes your connections to eavesdropping and Man-in-the-Middle (MITM) attacks. Do you want to continue?',
                                      style: TextStyle(color: textClr),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context, false),
                                        child: Text(isRtl ? 'إلغاء' : 'CANCEL', style: TextStyle(color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary)),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(context, true),
                                        child: Text(isRtl ? 'متابعة' : 'CONTINUE', style: TextStyle(color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed, fontWeight: FontWeight.bold)),
                                      ),
                                    ],
                                  );
                                },
                              );
                              if (confirm == true) {
                                settings.setBypassSSL(true);
                              }
                            } else {
                              settings.setBypassSSL(false);
                            }
                            triggerHaptic(settings);
                          },
                        ),
                        if (settings.bypassSSL) ...[
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                                width: 0.8,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    isRtl
                                        ? 'تحذير: تم تمكين تخطي شهادة SSL. اتصالاتك غير آمنة.'
                                        : 'WARNING: SSL certificate bypass is active. Your connections are insecure.',
                                    style: TextStyle(
                                      color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                      Divider(color: dividerColor, height: 1),
                      _buildUpdateHostsTile(context, settings),
                      Divider(color: dividerColor, height: 1),
                      _buildBackupTile(context, settings),
                      Divider(color: dividerColor, height: 1),
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: NeonGlowButton(
                          isFilled: false,
                          color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                          text: isRtl ? 'إعادة تعيين إلى الافتراضيات' : 'RESET TO DEFAULTS',
                          onPressed: () async {
                            triggerHaptic(settings);
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (context) {
                                return AlertDialog(
                                  backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
                                  title: Text(
                                    isRtl ? 'إعادة تعيين الإعدادات' : 'RESET SETTINGS',
                                    style: TextStyle(
                                      color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  content: Text(
                                    isRtl
                                        ? 'هل أنت متأكد من رغبتك في إعادة تعيين جميع الإعدادات إلى القيم الافتراضية؟'
                                        : 'Are you sure you want to reset all settings to their default values?',
                                    style: TextStyle(color: textClr),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, false),
                                      child: Text(isRtl ? 'إلغاء' : 'CANCEL', style: TextStyle(color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary)),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, true),
                                      child: Text(isRtl ? 'إعادة تعيين' : 'RESET', style: TextStyle(color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed, fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                );
                              },
                            );
                            if (confirm == true) {
                              await settings.resetToDefaults();
                              _uaController.text = settings.customUserAgent;
                              _proxyController.text = settings.proxyAddress;
                              _proxyHostController.text = settings.proxyHost;
                              _proxyPortController.text = settings.proxyPort.toString();
                              _proxyUsernameController.text = settings.proxyUsername;
                              _proxyPasswordController.text = settings.proxyPassword;
                              
                              if (context.mounted) {
                                ThemedSnackbar.show(
                                  context,
                                  message: isRtl ? 'تمت إعادة تعيين الإعدادات بنجاح!' : 'Settings reset to default values!',
                                  color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
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
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBrandingPanel(BuildContext context, SettingsProvider settings) {
    final isDark = settings.isDarkMode;
    final accentClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: DmxBackdropFilter(
        sigmaX: 10,
        sigmaY: 10,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: AppTheme.glassDecoration(
            borderRadius: 24,
            tintColor: accentClr,
            tintOpacity: 0.04,
            isDark: isDark,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              DmxAppIcon(
                size: 50,
                customColor: accentClr,
                showGlow: true,
              ),
              const SizedBox(height: 12),
              Text(
                L10n.of(context, 'app_title'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                  fontSize: 14,
                  color: textClr,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                L10n.of(context, 'settings_firmware'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: mutedClr,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                  fontSize: 9,
                ),
              ),
              const SizedBox(height: 12),
              Divider(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, height: 1.0),
              const SizedBox(height: 12),
              Text(
                L10n.of(context, 'settings_about_desc'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: secClr,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              Divider(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, height: 1.0),
              const SizedBox(height: 16),
              // Developer info
              Text(
                L10n.of(context, 'settings_developer'),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: accentClr,
                  fontSize: 9,
                  letterSpacing: 1.0,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              _buildContactTile(
                icon: Icons.person_outline,
                label: kDeveloperName,
                subtitle: L10n.of(context, 'developer_title'),
                isDark: isDark,
              ),
              const SizedBox(height: 8),
              _buildContactTile(
                icon: Icons.email_outlined,
                label: kDeveloperEmail,
                subtitle: L10n.of(context, 'tap_to_copy'),
                isDark: isDark,
                copyValue: kDeveloperEmail,
              ),
              const SizedBox(height: 8),
              _buildContactTile(
                icon: Icons.code,
                label: kDeveloperGithub,
                subtitle: L10n.of(context, 'tap_to_copy'),
                isDark: isDark,
                copyValue: kDeveloperGithub,
              ),
              const SizedBox(height: 8),
              _buildContactTile(
                icon: Icons.link,
                label: kDeveloperLinkedin,
                subtitle: L10n.of(context, 'tap_to_copy'),
                isDark: isDark,
                copyValue: kDeveloperLinkedin,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContactTile({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool isDark,
    String? copyValue,
  }) {
    final bgClr = isDark ? const Color(0xFF0F0F16) : const Color(0xFFF1F5F9);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final accClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return GestureDetector(
      onTap: copyValue != null
          ? () {
              Clipboard.setData(ClipboardData(text: copyValue));
              if (mounted) {
                ThemedSnackbar.show(
                  context,
                  message: L10n.of(context, 'copied'),
                  color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                  icon: Icons.check_circle_outline,
                  isDarkMode: isDark,
                );
              }
            }
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bgClr.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: accClr),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: textClr,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: secClr,
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ),
            if (copyValue != null)
              Icon(Icons.copy_rounded, size: 14, color: secClr),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsSection(
    BuildContext context, {
    required SettingsProvider settings,
    required String title,
    required List<Widget> children,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: DmxBackdropFilter(
        sigmaX: 10,
        sigmaY: 10,
        child: Container(
          width: double.infinity,
          decoration: AppTheme.glassDecoration(borderRadius: 20, isDark: settings.isDarkMode),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    left: 16.0,
                    top: 16.0,
                    right: 16.0,
                    bottom: 8.0,
                  ),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: settings.isDarkMode ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                      fontSize: 9,
                      letterSpacing: 1.0,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPathPickerTile(
    BuildContext context, {
    required SettingsProvider settings,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    VoidCallback? onClear,
  }) {
    final isDark = settings.isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final subClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final accentClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return ListTile(
      title: Text(
        title,
        style: TextStyle(
          color: textClr,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: subClr,
          fontSize: 10,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onClear != null)
            IconButton(
              icon: Icon(Icons.clear, color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed, size: 18),
              tooltip: L10n.isRtl(context) ? 'إعادة تعيين الافتراضي' : 'Reset to default',
              onPressed: onClear,
            ),
          IconButton(
            icon: const Icon(Icons.folder_open, size: 18),
            color: accentClr,
            onPressed: onTap,
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  Widget _buildSwitchTile({
    required SettingsProvider settings,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final isDark = settings.isDarkMode;
    final primaryClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final borderClr = isDark ? AppTheme.border : AppTheme.lightBorder;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final subClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeThumbColor: primaryClr,
      activeTrackColor: primaryClr.withValues(alpha: 0.2),
      inactiveThumbColor: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
      inactiveTrackColor: borderClr,
      title: Text(
        title,
        style: TextStyle(
          color: textClr,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: subClr, fontSize: 10),
      ),
    );
  }

  Widget _buildSliderTile({
    required SettingsProvider settings,
    required String title,
    required String subtitle,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    ValueChanged<double>? onChangeEnd,
  }) {
    final isDark = settings.isDarkMode;
    final primaryClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final glassBdr = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: textClr,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  color: primaryClr,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: primaryClr,
              inactiveTrackColor: glassBdr,
              thumbColor: primaryClr,
              overlayColor: primaryClr.withValues(alpha: 0.12),
              trackHeight: 3.0,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8.0),
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
    );
  }

  Widget _buildDropdownTile<T>({
    required SettingsProvider settings,
    required String title,
    required String subtitle,
    required T value,
    required List<T> items,
    Map<T, String>? itemLabels,
    required ValueChanged<T?> onChanged,
  }) {
    final isDark = settings.isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final subClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final bgClr = isDark ? AppTheme.background : AppTheme.lightBackground;
    final glassBdr = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
    final menuBgClr = isDark ? AppTheme.surface : AppTheme.lightSurface;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
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
                    color: textClr,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: subClr,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 120,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: bgClr.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: glassBdr, width: 0.8),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                dropdownColor: menuBgClr,
                value: value,
                isExpanded: true,
                icon: Icon(
                  Icons.arrow_drop_down,
                  color: secClr,
                  size: 18,
                ),
                style: TextStyle(
                  color: textClr,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
                items: items.map((item) {
                  return DropdownMenuItem<T>(
                    value: item,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(itemLabels != null ? itemLabels[item]! : item.toString()),
                    ),
                  );
                }).toList(),
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextFieldTile({
    required String title,
    required String subtitle,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
    required bool isDark,
  }) {
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final subClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: textClr,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(
              color: subClr,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            height: 42,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F0F16) : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark ? const Color(0x15FFFFFF) : const Color(0x0D000000),
                width: 0.8,
              ),
            ),
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: TextStyle(color: textClr, fontSize: 11, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateHostsTile(BuildContext context, SettingsProvider settings) {
    final isDark = settings.isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final subClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final isRtl = L10n.isRtl(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isRtl ? 'تحديث فلاتر الحجب' : 'UPDATE ADBLOCKER FILTERS',
                      style: TextStyle(color: textClr, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isRtl
                          ? 'تحديث يدوي لقوائم حجب الإعلانات والتعقب'
                          : 'Manually download and update ad & tracker blocklists',
                      style: TextStyle(color: subClr, fontSize: 10),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _isUpdatingHosts
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                        ),
                      ),
                    )
                  : IconButton(
                      icon: Icon(
                        Icons.sync,
                        color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                      ),
                      onPressed: () async {
                        triggerHaptic(settings);
                        setState(() {
                          _isUpdatingHosts = true;
                        });
                        ThemedSnackbar.show(
                          context,
                          message: isRtl
                              ? 'جاري تنزيل وتحديث فلاتر حجب الإعلانات...'
                              : 'Downloading and updating adblocker filters...',
                          color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                          icon: Icons.downloading,
                          isDarkMode: isDark,
                        );
                        try {
                          await AdBlocker.updateHosts();
                          if (context.mounted) {
                            ThemedSnackbar.show(
                              context,
                              message: isRtl
                                  ? 'تم تحديث فلاتر منع الإعلانات بنجاح!'
                                  : 'Adblocker filters updated successfully!',
                              color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                              icon: Icons.check_circle_outline,
                              isDarkMode: isDark,
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ThemedSnackbar.show(
                              context,
                              message: isRtl
                                  ? 'فشل تحديث فلاتر منع الإعلانات'
                                  : 'Failed to update adblocker filters',
                              color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                              icon: Icons.error_outline,
                              isDarkMode: isDark,
                            );
                          }
                        } finally {
                          if (mounted) {
                            setState(() {
                              _isUpdatingHosts = false;
                            });
                          }
                        }
                      },
                    ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBackupTile(BuildContext context, SettingsProvider settings) {
    final isDark = settings.isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final subClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L10n.of(context, 'settings_backup_title'),
            style: TextStyle(color: textClr, fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 2),
          Text(
            L10n.of(context, 'settings_backup_sub'),
            style: TextStyle(color: subClr, fontSize: 10),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: NeonGlowButton(
                  isFilled: false,
                  color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                  onPressed: () => _exportBackup(context, settings),
                  text: L10n.of(context, 'settings_export'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: NeonGlowButton(
                  isFilled: true,
                  color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                  onPressed: () => _importBackup(context, settings),
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

class PerformanceTelemetryCard extends StatelessWidget with HapticHelper {
  final SettingsProvider settings;
  const PerformanceTelemetryCard({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accentColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final subClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final glassBorder = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;

    return Consumer<DownloadProvider>(
      builder: (context, provider, child) {
        // Calculate metrics
        final activeDownloads = provider.tasks.where((t) => t.status == DownloadStatus.downloading).toList();
        final activeThreads = activeDownloads.fold<int>(0, (sum, t) => sum + t.threadCount);
        final totalSpeedBytes = activeDownloads.fold<double>(0.0, (sum, t) => sum + t.speed);
        
        // GPU Load Estimate
        final gpuLoad = settings.classicUi
            ? (isRtl ? 'منخفض (نمط الواجهة الكلاسيكي)' : 'LOW (Classic UI Mode)')
            : (isRtl ? 'متوسط (تأثيرات التوهج والضبابية)' : 'MODERATE (Glows & Blurs Active)');

        // Battery impact level
        String batteryImpact;
        Color batteryColor;
        if (settings.batterySaverMode) {
          batteryImpact = isRtl ? 'توفير الطاقة نشط (أمثل)' : 'SAVER ACTIVE (Optimal)';
          batteryColor = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
        } else if (activeDownloads.isNotEmpty) {
          batteryImpact = isRtl ? 'متوسط (تحميل نشط)' : 'MODERATE (Active downloads)';
          batteryColor = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
        } else {
          batteryImpact = isRtl ? 'منخفض جداً (خامل)' : 'VERY LOW (Idle)';
          batteryColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
        }

        // Memory load
        final cachedNodes = provider.tasks.length;
        final memoryLoad = isRtl 
            ? 'ممتاز ($cachedNodes عناصر مخزنة مؤقتاً)' 
            : 'EXCELLENT ($cachedNodes cached nodes)';

        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Telemetry Grid
              Row(
                children: [
                  Expanded(
                    child: _buildMetricTile(
                      context,
                      icon: Icons.speed,
                      title: isRtl ? 'السرعة الكلية' : 'Total Net Speed',
                      value: activeDownloads.isEmpty
                          ? '0.0 KB/s'
                          : '${formatBytes(totalSpeedBytes)}/s',
                      isDark: isDark,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildMetricTile(
                      context,
                      icon: Icons.dns_outlined,
                      title: isRtl ? 'قنوات الاتصال' : 'Active Connections',
                      value: activeDownloads.isEmpty
                          ? (isRtl ? 'خامل' : 'Idle')
                          : '$activeThreads ${isRtl ? 'خيوط' : 'threads'}',
                      isDark: isDark,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              
              // Diagnostics list
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: (isDark ? AppTheme.background : AppTheme.lightBackground).withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: glassBorder, width: 0.8),
                ),
                child: Column(
                  children: [
                    _buildDiagRow(
                      context,
                      label: isRtl ? 'حمل المعالج (CPU)' : 'CPU Threading Load',
                      value: activeDownloads.isEmpty
                          ? (isRtl ? 'خامل (0%)' : 'Idle (0%)')
                          : '${(activeThreads * 6).clamp(5, 95)}% ($activeThreads threads)',
                      isDark: isDark,
                    ),
                    const Divider(height: 16),
                    _buildDiagRow(
                      context,
                      label: isRtl ? 'حمل كارت الشاشة (GPU)' : 'GPU Rendering Load',
                      value: gpuLoad,
                      isDark: isDark,
                    ),
                    const Divider(height: 16),
                    _buildDiagRow(
                      context,
                      label: isRtl ? 'استهلاك الذاكرة (RAM)' : 'RAM Cache Load',
                      value: memoryLoad,
                      isDark: isDark,
                    ),
                    const Divider(height: 16),
                    _buildDiagRow(
                      context,
                      label: isRtl ? 'تأثير البطارية' : 'Battery Drainage Rate',
                      value: batteryImpact,
                      valueColor: batteryColor,
                      isDark: isDark,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Battery Saver Toggle
              SwitchListTile(
                value: settings.batterySaverMode,
                onChanged: (val) {
                  settings.setBatterySaverMode(val);
                  triggerHaptic(settings);
                },
                activeThumbColor: accentColor,
                activeTrackColor: accentColor.withValues(alpha: 0.2),
                inactiveThumbColor: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                inactiveTrackColor: isDark ? AppTheme.border : AppTheme.lightBorder,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  isRtl ? 'وضع توفير البطارية الأقصى' : 'Battery Saver Mode',
                  style: TextStyle(
                    color: textClr,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  isRtl
                      ? 'يقيد قنوات الاتصال إلى ٢، والتحميلات المتزامنة إلى ١، ويفرض الواجهة الكلاسيكية لتوفير الطاقة'
                      : 'Limits threads to 2, downloads to 1, and forces Classic UI to save battery',
                  style: TextStyle(color: subClr, fontSize: 10),
                ),
              ),
              const SizedBox(height: 12),
              // Reduce Visuals Toggle
              SwitchListTile(
                value: settings.reduceVisuals,
                onChanged: (val) {
                  settings.setReduceVisuals(val);
                  triggerHaptic(settings);
                },
                activeThumbColor: accentColor,
                activeTrackColor: accentColor.withValues(alpha: 0.2),
                inactiveThumbColor: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                inactiveTrackColor: isDark ? AppTheme.border : AppTheme.lightBorder,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  isRtl ? 'تقليل المؤثرات البصرية' : 'REDUCE VISUAL EFFECTS',
                  style: TextStyle(
                    color: textClr,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  isRtl
                      ? 'إيقاف تأثيرات التوهج والضبابية لتحسين الأداء على الأجهزة الضعيفة'
                      : 'Disable glow and blur effects to improve performance on low-end devices',
                  style: TextStyle(color: subClr, fontSize: 10),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMetricTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String value,
    required bool isDark,
  }) {
    final bg = isDark ? const Color(0xFF0F0F16) : const Color(0xFFF1F5F9);
    final border = isDark ? const Color(0x15FFFFFF) : const Color(0x0D000000);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
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
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagRow(
    BuildContext context, {
    required String label,
    required String value,
    Color? valueColor,
    required bool isDark,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
            fontSize: 10,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? (isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary),
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
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
