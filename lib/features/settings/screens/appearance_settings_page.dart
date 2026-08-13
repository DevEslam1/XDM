import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/haptic_helper.dart';
import '../provider/settings_provider.dart';
import '../widgets/settings_section_header.dart';
import '../widgets/settings_tiles.dart';

class AppearanceSettingsPage extends StatelessWidget with HapticHelper {
  const AppearanceSettingsPage({super.key});

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

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;

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
            title: isRtl ? 'المظهر والواجهة' : 'Theme & Display',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              DropdownTile<String>(
                accentColor: accent,
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
                onChanged: (val) {
                  if (val != null) {
                    settings.setThemeMode(val);
                    triggerHaptic(settings);
                  }
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: L10n.of(context, 'settings_classic_ui'),
                subtitle: settings.batterySaverMode
                    ? (isRtl
                        ? 'مفعل إجبارياً بسبب موفر البطارية'
                        : 'Forced ON by Battery Saver mode')
                    : L10n.of(context, 'settings_classic_ui_sub'),
                value: settings.classicUi,
                batterySaverOverride: settings.batterySaverMode,
                onChanged: (val) {
                  settings.setClassicUi(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'تأثيرات التوهج النيون' : 'Neon Glow Effects',
                subtitle: isRtl
                    ? 'تمكين التوهج الملون حول الأزرار والبطاقات'
                    : 'Enable glowing neon accents on interactive buttons and panels',
                value: settings.enableGlow,
                onChanged: (val) {
                  settings.setEnableGlow(val);
                  triggerHaptic(settings);
                },
              ),
              SliderTile(
                accentColor: accent,
                title:
                    isRtl ? 'شفافية شبكة الخلفية' : 'Background Grid Opacity',
                subtitle: '${settings.gridOpacity.round()}%',
                value: settings.gridOpacity,
                min: 0,
                max: 40,
                divisions: 40,
                onChanged: (val) {
                  settings.setGridOpacity(val);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title:
                    isRtl ? 'تقليل المؤثرات البصرية' : 'Reduce Visual Effects',
                subtitle: isRtl
                    ? 'تعطيل الخلفيات المتحركة لتوفير الأداء'
                    : 'Disable animated grid lines and background blur for max performance',
                value: settings.reduceVisuals,
                onChanged: (val) {
                  settings.setReduceVisuals(val);
                  triggerHaptic(settings);
                },
              ),
              DropdownTile<String>(
                accentColor: accent,
                title: L10n.of(context, 'settings_language'),
                subtitle: L10n.of(context, 'settings_language_sub'),
                value: settings.languageCode,
                items: const ['en', 'ar', 'de', 'es', 'fr'],
                itemLabels: const {
                  'en': 'ENGLISH',
                  'ar': 'العربية',
                  'de': 'DEUTSCH',
                  'es': 'ESPAÑOL',
                  'fr': 'FRANÇAIS',
                },
                onChanged: (val) {
                  if (val != null) {
                    settings.setLanguageCode(val);
                    triggerHaptic(settings);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          SettingsSectionHeader(
            title: isRtl ? 'التنبيهات والاهتزاز' : 'Alerts & Feedback',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'إشعارات النظام العامة' : 'Global Notifications',
                subtitle: isRtl
                    ? 'إظهار شريط التقدم والتنبيهات عند اكتمال التحميل'
                    : 'Show system progress bars and alerts when downloads complete',
                value: settings.notificationsEnabled,
                onChanged: (val) async {
                  settings.setNotificationsEnabled(val);
                  triggerHaptic(settings);
                  if (!val) {
                    await NotificationService().cancelAll();
                  }
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'صوت التنبيه عند الإكمال' : 'Completion Chime',
                subtitle: isRtl
                    ? 'تشغيل نغمة عند الانتهاء من تحميل الملف'
                    : 'Play notification chime when a file finishes downloading',
                value: settings.soundNotification,
                onChanged: (val) {
                  settings.setSoundNotification(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: L10n.of(context, 'settings_haptics'),
                subtitle: L10n.of(context, 'settings_haptics_sub'),
                value: settings.vibration,
                onChanged: (val) {
                  settings.setVibration(val);
                  triggerHaptic(settings);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          SettingsSectionHeader(
            title: isRtl ? 'ساعات الهدوء (Quiet Hours)' : 'Quiet Hours',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'تفعيل ساعات الهدوء' : 'Enable Quiet Hours',
                subtitle: isRtl
                    ? 'كتم أصوات الإشعارات تلقائياً خلال الفترة المحددة'
                    : 'Mute sounds and alert chimes during scheduled sleeping hours',
                value: settings.quietHoursEnabled,
                onChanged: (val) {
                  settings.setQuietHoursEnabled(val);
                  triggerHaptic(settings);
                },
              ),
              if (settings.quietHoursEnabled) ...[
                ActionSettingTile(
                  accentColor: accent,
                  title: isRtl ? 'وقت البدء' : 'Quiet Hours Start',
                  subtitle: 'Starts at ${settings.quietHoursStart}',
                  buttonText: settings.quietHoursStart,
                  onTap: () => _pickTime(
                    context,
                    settings.quietHoursStart,
                    (val) => settings.setQuietHoursStart(val),
                  ),
                ),
                ActionSettingTile(
                  accentColor: accent,
                  title: isRtl ? 'وقت الانتهاء' : 'Quiet Hours End',
                  subtitle: 'Ends at ${settings.quietHoursEnd}',
                  buttonText: settings.quietHoursEnd,
                  onTap: () => _pickTime(
                    context,
                    settings.quietHoursEnd,
                    (val) => settings.setQuietHoursEnd(val),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
