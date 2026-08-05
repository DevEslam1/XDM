import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/haptic_helper.dart';
import '../provider/settings_provider.dart';
import '../widgets/settings_section_header.dart';
import '../widgets/settings_tiles.dart';

class NotificationsSettingsPage extends StatelessWidget with HapticHelper {
  const NotificationsSettingsPage({super.key});

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
    final accent = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSectionHeader(
            title: isRtl ? 'التنبيهات والاهتزاز' : 'Alerts & Feedback',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            children: [
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'إشعارات النظام العامة' : 'Global Notifications',
                subtitle: isRtl
                    ? 'إظهار شريط التقدم والتنبيهات عند اكتمال التحميل'
                    : 'Show system progress bars and alerts when downloads complete',
                value: settings.notificationsEnabled,
                onChanged: (val) {
                  settings.setNotificationsEnabled(val);
                  triggerHaptic(settings);
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
          const SizedBox(height: 12),
          SettingsSectionHeader(
            title: isRtl ? 'ساعات الهدوء (Do Not Disturb)' : 'Quiet Hours',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
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
