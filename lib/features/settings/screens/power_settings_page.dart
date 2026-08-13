import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/haptic_helper.dart';
import '../provider/settings_provider.dart';
import '../widgets/settings_section_header.dart';
import '../widgets/settings_tiles.dart';
import '../widgets/system_monitors_card.dart';

class PowerSettingsPage extends StatelessWidget with HapticHelper {
  const PowerSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonOrange : AppTheme.lightNeonOrange;

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
          SystemMonitorsCard(
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionHeader(
            title: isRtl ? 'إدارة الطاقة والبطارية' : 'Power Management',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'وضع توفير البطارية' : 'Battery Saver Mode',
                subtitle: isRtl
                    ? 'يحدد التحميلات المتزامنة بـ 1، الخيوط بـ 2، ويفعل الواجهة الكلاسيكية'
                    : 'Limits downloads to 1, threads to 2, and forces Classic UI mode',
                value: settings.batterySaverMode,
                onChanged: (val) {
                  settings.setBatterySaverMode(val);
                  triggerHaptic(settings);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsSectionHeader(
            title: isRtl
                ? 'تحسينات الأداء والذاكرة'
                : 'Power & Performance Tuning',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              SwitchTile(
                accentColor: accent,
                title:
                    isRtl ? 'حوض المعالجات الذكي' : 'Power-Aware Isolate Pool',
                subtitle: isRtl
                    ? 'تعديل عدد معالجات الخلفية تلقائياً بناءً على مستوى البطارية'
                    : 'Dynamically scale isolate worker pool based on battery level',
                value: settings.powerAwareIsolatePool,
                onChanged: (val) {
                  settings.setPowerAwareIsolatePool(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'محدد الحرارة للخيوط' : 'Thermal Thread Limiter',
                subtitle: isRtl
                    ? 'تقليل الخيوط عند ارتفاع حرارة الجهاز لتجنب التباطؤ'
                    : 'Throttle thread concurrency during thermal throttling events',
                value: settings.thermalThreadLimiting,
                onChanged: (val) {
                  settings.setThermalThreadLimiting(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl
                    ? 'توفير البطارية عند التقطيع'
                    : 'Auto Battery Saver on Jank',
                subtitle: isRtl
                    ? 'تفعيل موفر البطارية تلقائياً عند سقوط الفريمات المتكرر'
                    : 'Auto-enable Battery Saver mode if 3 consecutive frame windows drop below 92% FPS',
                value: settings.jankAutoBatterySaver,
                onChanged: (val) {
                  settings.setJankAutoBatterySaver(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'دفعة الكتابة على القرص' : 'Disk Write Batching',
                subtitle: isRtl
                    ? 'تجميع كتابات القرص في دُفعات 256KB لتخفيف الضغط على I/O'
                    : 'Buffer disk writes in 256KB chunks to maximize Flash SSD lifespan',
                value: settings.diskWriteBatching,
                onChanged: (val) {
                  settings.setDiskWriteBatching(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl
                    ? 'خنق سرعة الشبكة حسب الطاقة'
                    : 'Power Bandwidth Throttling',
                subtitle: isRtl
                    ? 'تخفيض السرعة تلقائياً في وضع البطارية المنخفضة'
                    : 'Throttle max throughput on low battery to conserve energy',
                value: settings.powerBandwidthThrottling,
                onChanged: (val) {
                  settings.setPowerBandwidthThrottling(val);
                  triggerHaptic(settings);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
