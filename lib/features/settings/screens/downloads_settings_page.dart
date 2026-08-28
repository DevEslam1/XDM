import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/constants.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../provider/settings_provider.dart';
import '../widgets/browser_extensions_sheet.dart';
import '../widgets/settings_section_header.dart';
import '../widgets/settings_tiles.dart';

class DownloadsSettingsPage extends StatelessWidget with HapticHelper {
  const DownloadsSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(
        left: 12.0,
        right: 12.0,
        top: 16.0,
        bottom: 84.0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSectionHeader(
            title: isRtl ? 'محرك التحميل والسرعة' : 'Engine & Concurrency',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              SwitchTile(
                accentColor: accent,
                title: L10n.of(context, 'settings_auto_resume'),
                subtitle: L10n.of(context, 'settings_auto_resume_sub'),
                value: settings.autoStart,
                onChanged: (val) {
                  settings.setAutoStart(val);
                  triggerHaptic(settings);
                },
              ),
              DropdownTile<int>(
                accentColor: accent,
                title: L10n.of(context, 'settings_max_channels'),
                subtitle: settings.batterySaverMode
                    ? (isRtl
                        ? 'محدود بـ ${settings.maxDownloads} بسبب موفر البطارية'
                        : 'Limited to ${settings.maxDownloads} by Battery Saver')
                    : L10n.of(context, 'settings_max_channels_sub'),
                value: settings.maxDownloads,
                items: const [1, 2, 3, 5, 8],
                batterySaverOverride: settings.batterySaverMode,
                onChanged: (val) {
                  if (val != null) {
                    settings.setMaxDownloads(val);
                    triggerHaptic(settings);
                  }
                },
              ),
              DropdownTile<int>(
                accentColor: accent,
                title: L10n.of(context, 'settings_default_threads'),
                subtitle: settings.batterySaverMode
                    ? (isRtl
                        ? 'محدود بـ ${settings.effectiveDefaultThreadCount} بسبب موفر البطارية'
                        : 'Limited to ${settings.effectiveDefaultThreadCount} by Battery Saver')
                    : L10n.of(context, 'settings_default_threads_sub'),
                value: settings.defaultThreadCount,
                items: kAvailableThreadOptions,
                batterySaverOverride: settings.batterySaverMode,
                onChanged: (val) {
                  if (val != null) {
                    settings.setDefaultThreadCount(val);
                    triggerHaptic(settings);
                  }
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: L10n.of(context, 'settings_adaptive_threads'),
                subtitle: L10n.of(context, 'settings_adaptive_threads_sub'),
                value: settings.adaptiveThreads,
                onChanged: (val) {
                  settings.setAdaptiveThreads(val);
                  triggerHaptic(settings);
                },
              ),
              SliderTile(
                accentColor: accent,
                title: L10n.of(context, 'settings_speed_limit'),
                subtitle: settings.speedLimitMb == 0
                    ? (isRtl ? 'غير محدود' : 'Unlimited (0 MB/s)')
                    : '${settings.speedLimitMb.toStringAsFixed(1)} MB/s',
                value: settings.speedLimitMb,
                min: 0,
                max: 100,
                divisions: 100,
                onChanged: (val) {
                  settings.setSpeedLimit(val);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsSectionHeader(
            title:
                isRtl ? 'سلامة الملفات وإعادة المحاولة' : 'Integrity & Retries',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              SwitchTile(
                accentColor: accent,
                title: L10n.of(context, 'settings_auto_verify_checksum'),
                subtitle: L10n.of(context, 'settings_auto_verify_checksum_sub'),
                value: settings.autoVerifyChecksum,
                onChanged: (val) {
                  settings.setAutoVerifyChecksum(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'فحص سلامة الاستئناف' : 'Resume Integrity Check',
                subtitle: isRtl
                    ? 'أخذ عينات 64 كيلو بايت للتأكد من عدم تغير الملف على السيرفر'
                    : 'Spot-check 64KB samples at start/mid/end before resuming',
                value: settings.resumeIntegrityCheck,
                onChanged: (val) {
                  settings.setResumeIntegrityCheck(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl
                    ? 'إعادة المحاولة التلقائية'
                    : 'Auto-retry Failed Downloads',
                subtitle: isRtl
                    ? 'إعادة محاولة التحميلات الفاشلة تلقائياً بزيادة زمنية'
                    : 'Automatically retry failed HTTP connections with exponential backoff',
                value: settings.autoRetryEnabled,
                onChanged: (val) {
                  settings.setAutoRetryEnabled(val);
                  triggerHaptic(settings);
                },
              ),
              DropdownTile<int>(
                accentColor: accent,
                title:
                    isRtl ? 'أقصى عدد لمحاولات الإعادة' : 'Max Retry Attempts',
                subtitle: '${settings.maxRetries} attempts',
                value: settings.maxRetries,
                items: const [1, 2, 3, 5, 10],
                onChanged: (val) {
                  if (val != null) {
                    settings.setMaxRetries(val);
                    triggerHaptic(settings);
                  }
                },
              ),
              DropdownTile<int>(
                accentColor: accent,
                title: isRtl ? 'تأخير إعادة المحاولة' : 'Retry Delay',
                subtitle: '${settings.retryDelaySeconds} seconds',
                value: settings.retryDelaySeconds,
                items: const [5, 10, 30, 60],
                itemLabels: const {
                  5: '5s',
                  10: '10s',
                  30: '30s',
                  60: '60s',
                },
                onChanged: (val) {
                  if (val != null) {
                    settings.setRetryDelaySeconds(val);
                    triggerHaptic(settings);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsSectionHeader(
            title: isRtl ? 'المجلدات والتنظيف' : 'Storage & Files',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              PathPickerTile(
                accentColor: accent,
                title: isRtl
                    ? 'مجلد التحميل الافتراضي'
                    : 'Default Download Folder',
                subtitle: settings.customDownloadPath?.isNotEmpty == true
                    ? settings.customDownloadPath!
                    : (isRtl
                        ? 'تلقائي (Downloads/XDM)'
                        : 'Default (Downloads/XDM)'),
                onTap: () async {
                  triggerHaptic(settings);
                  final result = await FilePicker.getDirectoryPath();
                  if (result != null && result.isNotEmpty) {
                    await settings.setCustomDownloadPath(result);
                  }
                },
                onClear: settings.customDownloadPath != null
                    ? () {
                        settings.setCustomDownloadPath(null);
                        triggerHaptic(settings);
                      }
                    : null,
              ),
              SwitchTile(
                accentColor: accent,
                title:
                    isRtl ? 'مجلدات فرعية حسب التصنيف' : 'Category Subfolders',
                subtitle: isRtl
                    ? 'حفظ الملفات تلقائياً في مجلدات فرعية (Videos, Music, Documents...)'
                    : 'Automatically organize completed files into subfolders by category',
                value: settings.categoryFolders,
                onChanged: (val) {
                  settings.setCategoryFolders(val);
                  triggerHaptic(settings);
                },
              ),
              DropdownTile<int>(
                accentColor: accent,
                title: isRtl ? 'التنظيف التلقائي للسجلات' : 'Auto-cleanup Logs',
                subtitle: settings.cleanupDays == 0
                    ? (isRtl ? 'معطل' : 'Disabled (0 days)')
                    : '${settings.cleanupDays} days',
                value: settings.cleanupDays,
                items: const [0, 7, 30],
                itemLabels: const {
                  0: 'DISABLED',
                  7: '7 DAYS',
                  30: '30 DAYS',
                },
                onChanged: (val) {
                  if (val != null) {
                    settings.setCleanupDays(val);
                    triggerHaptic(settings);
                  }
                },
              ),
              DropdownTile<int>(
                accentColor: accent,
                title: isRtl
                    ? 'أقصى ملفات متزامنة لكل تورنت'
                    : 'Max Concurrent Files Per Torrent',
                subtitle: settings.maxConcurrentFilesPerTorrent == 0
                    ? (isRtl ? 'غير محدود' : 'Unlimited (0)')
                    : '${settings.maxConcurrentFilesPerTorrent} files',
                value: settings.maxConcurrentFilesPerTorrent,
                items: const [0, 1, 2, 3, 5, 10],
                onChanged: (val) {
                  if (val != null) {
                    settings.setMaxConcurrentFilesPerTorrent(val);
                    triggerHaptic(settings);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          SettingsSectionHeader(
            title: isRtl
                ? 'ملحقات المتصفح والتكامل'
                : 'Browser Plugins & Interception',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              ActionTile(
                accentColor: accent,
                icon: Icons.extension_rounded,
                title: isRtl
                    ? 'إعداد ملحقات المتصفح (Firefox & Safari)'
                    : 'Browser Plugins (Firefox & Safari)',
                subtitle: isRtl
                    ? 'إلغاء تنزيلات المتصفح تلقائياً وتحويلها إلى XDM'
                    : 'Auto-intercept & redirect downloads from Firefox Android & Safari iOS to XDM',
                onTap: () {
                  triggerHaptic(settings);
                  BrowserExtensionsSheet.show(context);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
