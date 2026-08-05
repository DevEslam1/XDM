import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/haptic_helper.dart';
import '../provider/settings_provider.dart';
import '../widgets/settings_section_header.dart';
import '../widgets/settings_tiles.dart';

class AppearanceSettingsPage extends StatelessWidget with HapticHelper {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 16.0),
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
                subtitle: isRtl ? 'فاتح / داكن / تتبع النظام' : 'Light / Dark / Follow System',
                value: settings.themeMode,
                items: const ['light', 'dark', 'system'],
                itemLabels: const {
                  'light': 'LIGHT',
                  'dark': 'DARK',
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
                subtitle: isRtl ? 'تمكين التوهج الملون حول الأزرار والبطاقات' : 'Enable glowing neon accents on interactive buttons and panels',
                value: settings.enableGlow,
                onChanged: (val) {
                  settings.setEnableGlow(val);
                  triggerHaptic(settings);
                },
              ),
              SliderTile(
                accentColor: accent,
                title: isRtl ? 'شفافية شبكة الخلفية' : 'Background Grid Opacity',
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
                title: isRtl ? 'تقليل المؤثرات البصرية' : 'Reduce Visual Effects',
                subtitle: isRtl ? 'تعطيل الخلفيات المتحركة لتوفير الأداء' : 'Disable animated grid lines and background blur for max performance',
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
        ],
      ),
    );
  }
}
