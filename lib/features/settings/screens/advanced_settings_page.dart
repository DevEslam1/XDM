import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/constants.dart';
import '../../../core/services/app_lock_service.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../../shared/design/dmx_design.dart';
import '../provider/settings_provider.dart';
import '../widgets/app_lock_screen.dart';
import '../widgets/settings_section_header.dart';
import '../widgets/settings_tiles.dart';
import '../utils/backup_helper.dart';

class AdvancedSettingsPage extends StatefulWidget {
  const AdvancedSettingsPage({super.key});

  @override
  State<AdvancedSettingsPage> createState() => _AdvancedSettingsPageState();
}

class _AdvancedSettingsPageState extends State<AdvancedSettingsPage>
    with HapticHelper {
  late final TextEditingController _uaController;
  bool _appLockEnabled = false;

  @override
  void initState() {
    super.initState();
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    _uaController = TextEditingController(text: settings.customUserAgent);
    _loadAppLockState();
  }

  @override
  void dispose() {
    _uaController.dispose();
    super.dispose();
  }

  Future<void> _loadAppLockState() async {
    final enabled = await AppLockService.isLockEnabled();
    if (mounted) setState(() => _appLockEnabled = enabled);
  }

  Future<void> _setAppLock(bool enabled) async {
    if (enabled) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const AppLockScreen(isSettingUp: true),
        ),
      );
      await _loadAppLockState();
    } else {
      await AppLockService.disableLock();
      if (mounted) setState(() => _appLockEnabled = false);
    }
  }

  Future<void> _pickTime(
    BuildContext context,
    String currentTime,
    ValueChanged<String> onSelect,
  ) async {
    final parts = currentTime.split(':');
    final initialHour = parts.length == 2 ? (int.tryParse(parts[0]) ?? 23) : 23;
    final initialMinute = parts.length == 2 ? (int.tryParse(parts[1]) ?? 0) : 0;

    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initialHour, minute: initialMinute),
    );

    if (picked != null) {
      final h = picked.hour.toString().padLeft(2, '0');
      final m = picked.minute.toString().padLeft(2, '0');
      onSelect('$h:$m');
    }
  }

  void _showResetConfirmDialog(
      BuildContext context, SettingsProvider settings) async {
    final confirmed = await DmxConfirmDialog.show(
      context,
      title: L10n.of(context, 'settings_reset_confirm_title'),
      message: L10n.of(context, 'settings_reset_confirm_body'),
      confirmLabel: L10n.of(context, 'settings_reset_confirm_btn'),
      cancelLabel: L10n.of(context, 'cancel_btn'),
      isDestructive: true,
      icon: Icons.restore_rounded,
    );
    if (confirmed == true && context.mounted) {
      await settings.resetToDefaults();
      if (context.mounted) {
        ThemedSnackbar.show(
          context,
          message: L10n.of(context, 'settings_reset_done'),
          color: AppTheme.neonGreen,
          icon: Icons.check_circle_outline,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSectionHeader(
            title: isRtl ? 'وضع المطور والأمان' : 'Developer & App Security',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              SwitchTile(
                accentColor: accent,
                title: 'Enable Developer Mode',
                subtitle:
                    'Unlocks advanced debugging, SSL configuration, and internal logs',
                value: settings.developerMode,
                onChanged: (val) {
                  settings.toggleDeveloperMode();
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'قفل التطبيق (PIN)' : 'App Lock (PIN)',
                subtitle: isRtl
                    ? 'حماية التطبيق برقم سري لمنع الاستخدام غير المصرح'
                    : 'Protect XDM with a passcode PIN upon launch',
                value: _appLockEnabled,
                onChanged: (val) => _setAppLock(val),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsSectionHeader(
            title: isRtl ? 'يوتيوب واستخراج الوسائط' : 'YouTube & Media Extraction',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              TextFieldTile(
                accentColor: accent,
                title: isRtl
                    ? 'وكيل المستخدم المخصص (User-Agent)'
                    : 'Custom User-Agent',
                subtitle: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)...',
                controller: _uaController,
                onChanged: (val) => settings.setCustomUserAgent(val),
                onSubmitted: (val) => settings.setCustomUserAgent(val),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsSectionHeader(
            title: isRtl ? 'جدولة النطاق الترددي' : 'Bandwidth Schedule',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              SwitchTile(
                accentColor: accent,
                title:
                    isRtl ? 'تفعيل جدولة السرعة' : 'Enable Bandwidth Schedule',
                subtitle: isRtl
                    ? 'تطبيق حد سرعة مخصص خلال ساعات محددة تلقائياً'
                    : 'Automatically restrict download speed during scheduled hours',
                value: settings.bandwidthScheduleEnabled,
                onChanged: (val) {
                  settings.setBandwidthScheduleEnabled(val);
                  triggerHaptic(settings);
                },
              ),
              if (settings.bandwidthScheduleEnabled) ...[
                ActionSettingTile(
                  accentColor: accent,
                  title: isRtl ? 'وقت بداية الجدولة' : 'Schedule Start Time',
                  subtitle: 'Starts at ${settings.scheduleStartTime}',
                  buttonText: settings.scheduleStartTime,
                  onTap: () => _pickTime(
                    context,
                    settings.scheduleStartTime,
                    (val) => settings.setScheduleStartTime(val),
                  ),
                ),
                ActionSettingTile(
                  accentColor: accent,
                  title: isRtl ? 'وقت نهاية الجدولة' : 'Schedule End Time',
                  subtitle: 'Ends at ${settings.scheduleEndTime}',
                  buttonText: settings.scheduleEndTime,
                  onTap: () => _pickTime(
                    context,
                    settings.scheduleEndTime,
                    (val) => settings.setScheduleEndTime(val),
                  ),
                ),
                SliderTile(
                  accentColor: accent,
                  title: isRtl ? 'سرعة الجدولة' : 'Scheduled Speed Limit',
                  subtitle: settings.scheduleSpeedLimitMb == 0
                      ? (isRtl ? 'غير محدود' : 'Unlimited')
                      : '${settings.scheduleSpeedLimitMb.toStringAsFixed(1)} MB/s',
                  value: settings.scheduleSpeedLimitMb,
                  min: 0,
                  max: 100,
                  divisions: 100,
                  onChanged: (val) {
                    settings.setScheduleSpeedLimitMb(val);
                  },
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          SettingsSectionHeader(
            title: isRtl ? 'النسخ الاحتياطي والاستعادة' : 'Backup & Recovery',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              ActionSettingTile(
                accentColor:
                    isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                title: isRtl
                    ? 'تصدير النسخة الاحتياطية'
                    : 'Export Settings Backup',
                subtitle:
                    'Save all configurations and bookmarks to a JSON file',
                buttonText: 'EXPORT',
                onTap: () => BackupHelper.exportBackup(context, settings),
              ),
              ActionSettingTile(
                accentColor: accent,
                title: isRtl
                    ? 'استعادة النسخة الاحتياطية'
                    : 'Import Settings Backup',
                subtitle: 'Restore settings and bookmarks from a backup file',
                buttonText: 'IMPORT',
                onTap: () => BackupHelper.importBackup(context, settings),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsSectionHeader(
            title:
                isRtl ? 'إعادة التعيين والمعلومات' : 'Reset & Developer Info',
            accentColor: AppTheme.neonRed,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              ActionSettingTile(
                accentColor: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                isDestructive: true,
                title: isRtl ? 'إعادة تعيين الإعدادات' : 'Reset All Settings',
                subtitle:
                    'Restore all application preferences to factory defaults',
                buttonText: 'RESET',
                onTap: () => _showResetConfirmDialog(context, settings),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _DeveloperAboutCard(settings: settings, isDark: isDark),
        ],
      ),
    );
  }
}

class _DeveloperAboutCard extends StatelessWidget {
  final SettingsProvider settings;
  final bool isDark;

  const _DeveloperAboutCard({
    required this.settings,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final cyanClr = isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.surface : AppTheme.lightSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: cyanClr.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded, color: cyanClr, size: 18),
              const SizedBox(width: 8),
              Text(
                'XDM (Extreme Download Manager)',
                style: TextStyle(
                  color:
                      isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                  fontFamily: 'Space Grotesk',
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Version 3.0.0+1 • Cross-Platform Engine',
            style: TextStyle(
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
              fontFamily: 'Inter',
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              InkWell(
                onTap: () => launchUrl(Uri.parse('mailto:$kDeveloperEmail')),
                child: Chip(
                  avatar:
                      FaIcon(FontAwesomeIcons.google, size: 12, color: cyanClr),
                  label: const Text(kDeveloperEmail,
                      style: TextStyle(fontSize: 11)),
                  backgroundColor: isDark
                      ? AppTheme.surfaceRaised
                      : AppTheme.lightSurfaceRaised,
                ),
              ),
              InkWell(
                onTap: () => launchUrl(Uri.parse('https://$kDeveloperGithub')),
                child: Chip(
                  avatar:
                      FaIcon(FontAwesomeIcons.github, size: 12, color: cyanClr),
                  label: const Text(kDeveloperGithub,
                      style: TextStyle(fontSize: 11)),
                  backgroundColor: isDark
                      ? AppTheme.surfaceRaised
                      : AppTheme.lightSurfaceRaised,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
