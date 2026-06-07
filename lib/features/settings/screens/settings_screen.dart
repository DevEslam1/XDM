import 'dart:io';
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
  bool _isUpdatingHosts = false;

  @override
  void initState() {
    super.initState();
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    _uaController = TextEditingController(text: settings.customUserAgent);
    _proxyController = TextEditingController(text: settings.proxyAddress);
  }

  @override
  void dispose() {
    _uaController.dispose();
    _proxyController.dispose();
    super.dispose();
  }

  void _exportBackup(BuildContext context, SettingsProvider settings) async {
    triggerHaptic(settings);
    final provider = Provider.of<DownloadProvider>(context, listen: false);
    final jsonStr = provider.exportBackupJson();
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
    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      final jsonStr = await file.readAsString();
      final success = await provider.importBackupJson(jsonStr);
      if (context.mounted) {
        ThemedSnackbar.show(
          context,
          message: success
              ? (isRtl ? 'تم استيراد النسخة الاحتياطية بنجاح' : 'Backup imported successfully')
              : (isRtl ? 'فشل استيراد النسخة الاحتياطية' : 'Failed to import backup'),
          color: success
              ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
              : (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed),
          icon: success ? Icons.check_circle_outline : Icons.error_outline,
          isDarkMode: isDark,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final dividerColor = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: ClipRect(
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
                      _buildSwitchTile(
                        settings: settings,
                        title: L10n.of(context, 'settings_theme'),
                        subtitle: L10n.of(context, 'settings_theme_sub'),
                        value: settings.isDarkMode,
                        onChanged: (val) {
                          settings.setIsDarkMode(val);
                          triggerHaptic(settings);
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

                  // 5. ADVANCED POWER CONSOLE
                  _buildSettingsSection(
                    context,
                    settings: settings,
                    title: L10n.of(context, 'settings_adv_console'),
                    children: [
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
                          title: L10n.of(context, 'settings_proxy_address'),
                          subtitle: 'e.g. 10.0.0.1:8080',
                          controller: _proxyController,
                          onChanged: (val) {
                            settings.setProxyAddress(val);
                          },
                          isDark: isDark,
                        ),
                        Divider(color: dividerColor, height: 1),
                        _buildSwitchTile(
                          settings: settings,
                          title: L10n.of(context, 'settings_bypass_ssl'),
                          subtitle: L10n.of(context, 'settings_bypass_ssl_sub'),
                          value: settings.bypassSSL,
                          onChanged: (val) {
                            settings.setBypassSSL(val);
                            triggerHaptic(settings);
                          },
                        ),
                      ],
                      Divider(color: dividerColor, height: 1),
                      _buildUpdateHostsTile(context, settings),
                      Divider(color: dividerColor, height: 1),
                      _buildBackupTile(context, settings),
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
            ],
          ),
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
            width: 110,
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
                    child: Text(itemLabels != null ? itemLabels[item]! : item.toString()),
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
