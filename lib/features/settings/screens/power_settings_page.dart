import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/device_tier.dart';
import '../../../core/services/power_monitor.dart';
import '../../../core/services/service_registry.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_design.dart';
import '../provider/settings_provider.dart';
import '../widgets/settings_section_header.dart';
import '../widgets/settings_tiles.dart';
import '../widgets/system_monitors_card.dart';

enum _PerfProfile { saver, balanced, high, auto }

/// Plan 07 §7.7 — the unified "Performance & Resources" control center.
///
/// Every control here maps to a real consumer:
///  - Max download threads   → SettingsProvider.defaultThreadCount (isolate/HTTP engines)
///  - Isolate worker pool     → SettingsProvider.powerAwareIsolatePool (download_isolate_pool)
///  - Thermal thread limiter  → PowerMonitor.thermalThreadLimitingEnabled
///  - Image cache             → PaintingBinding.imageCache (wired in main.dart)
///  - Clear caches now        → ServiceRegistry.broadcastMemoryPressure()
///  - Visual quality          → reduceVisuals / enableGlow / gridOpacity flags
///  - Auto-reduce on jank      → FrameWatchdog jank handler in main.dart (release)
///  - Write buffering          → SettingsProvider.diskWriteBatching
///  - Power bandwidth throttle → PowerMonitor.powerBandwidthThrottlingEnabled
///  - Charging / cellular gates→ SettingsProvider (enforced by download orchestrator)
///  - Ignore battery optim.    → PowerMonitor.requestIgnoreBatteryOptimizations()
class PowerSettingsPage extends StatelessWidget with HapticHelper {
  const PowerSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonOrange : AppTheme.lightNeonOrange;
    final caps = DeviceTierService.current;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(
        left: 12.0,
        right: 12.0,
        top: 12.0,
        bottom: 80.0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SystemMonitorsCard(accentColor: accent, isDark: isDark),
          const SizedBox(height: 12),

          // ── PERFORMANCE PROFILE ──────────────────────────────────────────
          SettingsSectionHeader(
            title: isRtl ? 'ملف الأداء' : 'Performance Profile',
            accentColor: accent,
            isDark: isDark,
          ),
          _buildProfileSelector(context, settings, accent, isDark, isRtl, caps),
          const SizedBox(height: 12),

          // ── CPU ──────────────────────────────────────────────────────────
          SettingsSectionHeader(
            title: isRtl ? 'المعالج' : 'CPU',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              DropdownTile<int>(
                accentColor: accent,
                title: isRtl ? 'أقصى عدد خيوط التحميل' : 'Max download threads',
                subtitle: isRtl
                    ? 'الاتصالات المتوازية لكل تحميل'
                    : 'Parallel connections used per download',
                value: settings.configuredDefaultThreadCount,
                items: _threadItems(settings.configuredDefaultThreadCount),
                onChanged: settings.batterySaverMode
                    ? null
                    : (val) {
                        if (val != null) {
                          settings.setDefaultThreadCount(val);
                          triggerHaptic(settings);
                        }
                      },
                batterySaverOverride: settings.batterySaverMode,
              ),
              DropdownTile<bool>(
                accentColor: accent,
                title: isRtl ? 'حوض معالجات العمل' : 'Isolate worker pool',
                subtitle: isRtl
                    ? 'تلقائي: يتكيّف مع البطارية والحرارة — مثبّت: حجم ثابت'
                    : 'Auto scales with battery/thermal — Pinned keeps it fixed',
                value: settings.powerAwareIsolatePool,
                items: const [true, false],
                itemLabels: {
                  true: isRtl ? 'تلقائي (واعٍ بالطاقة)' : 'Auto (power-aware)',
                  false: isRtl ? 'مثبّت (أقصى)' : 'Pinned (max)',
                },
                onChanged: (val) {
                  if (val != null) {
                    settings.setPowerAwareIsolatePool(val);
                    triggerHaptic(settings);
                  }
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'محدد الحرارة للخيوط' : 'Thermal thread limiter',
                subtitle: isRtl
                    ? 'تقليل التزامن عند ارتفاع حرارة الجهاز'
                    : 'Throttle thread concurrency during thermal events',
                value: settings.thermalThreadLimiting,
                onChanged: (val) {
                  settings.setThermalThreadLimiting(val);
                  triggerHaptic(settings);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── MEMORY ───────────────────────────────────────────────────────
          SettingsSectionHeader(
            title: isRtl ? 'الذاكرة' : 'Memory',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              _ImageCacheSlider(accentColor: accent, isRtl: isRtl),
              ActionSettingTile(
                accentColor: accent,
                title: isRtl ? 'مسح الذاكرة المؤقتة الآن' : 'Clear caches now',
                subtitle: isRtl
                    ? 'تحرير ذاكرة الصور والذاكرة المؤقتة غير الأساسية'
                    : 'Free image memory and non-essential caches immediately',
                buttonText: isRtl ? 'مسح' : 'Clear',
                onTap: () {
                  ServiceRegistry.broadcastMemoryPressure();
                  PaintingBinding.instance.imageCache.clear();
                  PaintingBinding.instance.imageCache.clearLiveImages();
                  triggerHaptic(settings);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                          isRtl ? 'تم مسح الذاكرة المؤقتة' : 'Caches cleared'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── GPU / VISUALS ────────────────────────────────────────────────
          SettingsSectionHeader(
            title: isRtl ? 'الرسوميات والمؤثرات' : 'GPU / Visuals',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              DropdownTile<VisualQuality>(
                accentColor: accent,
                title: isRtl ? 'جودة العرض' : 'Visual quality',
                subtitle: isRtl
                    ? 'كامل: كل المؤثرات — خفيف: بلا توهج — إيقاف: بلا شبكة'
                    : 'Full: all effects — Lite: no glow — Off: no grid',
                value: settings.visualQuality,
                items: const [
                  VisualQuality.full,
                  VisualQuality.lite,
                  VisualQuality.off,
                ],
                itemLabels: {
                  VisualQuality.full: isRtl ? 'كامل' : 'Full',
                  VisualQuality.lite: isRtl ? 'خفيف' : 'Lite',
                  VisualQuality.off: isRtl ? 'إيقاف' : 'Off',
                },
                onChanged: settings.batterySaverMode
                    ? null
                    : (val) {
                        if (val != null) {
                          settings.setVisualQuality(val);
                          triggerHaptic(settings);
                        }
                      },
                batterySaverOverride: settings.batterySaverMode,
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl
                    ? 'تقليل المؤثرات تلقائياً عند التقطيع'
                    : 'Auto-reduce effects on jank',
                subtitle: isRtl
                    ? 'خفض جودة العرض تدريجياً عند استمرار سقوط الإطارات'
                    : 'Gradually step visual quality down on sustained frame drops',
                value: settings.autoReduceEffectsOnJank,
                onChanged: (val) {
                  settings.setAutoReduceEffectsOnJank(val);
                  triggerHaptic(settings);
                },
              ),
              if (settings.autoReduceEffectsOnJank)
                SwitchTile(
                  accentColor: accent,
                  title: isRtl
                      ? 'تقليل التحميلات كملاذ أخير'
                      : 'Reduce downloads as last resort',
                  subtitle: isRtl
                      ? 'إذا استمر التقطيع بعد إيقاف كل المؤثرات، فعّل موفر البطارية'
                      : 'If still janky after visuals are off, enable Battery Saver',
                  value: settings.jankAutoBatterySaver,
                  onChanged: (val) {
                    settings.setJankAutoBatterySaver(val);
                    triggerHaptic(settings);
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),

          // ── DISK / IO ────────────────────────────────────────────────────
          SettingsSectionHeader(
            title: isRtl ? 'القرص والإدخال/الإخراج' : 'Disk / IO',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'تجميع الكتابة للقرص' : 'Write buffering',
                subtitle: isRtl
                    ? 'تجميع كتابات القرص لتقليل ضغط الإدخال/الإخراج'
                    : 'Batch disk writes to reduce IO pressure and flash wear',
                value: settings.diskWriteBatching,
                onChanged: (val) {
                  settings.setDiskWriteBatching(val);
                  triggerHaptic(settings);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── BATTERY / BACKGROUND ─────────────────────────────────────────
          SettingsSectionHeader(
            title: isRtl ? 'البطارية والخلفية' : 'Battery / Background',
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
                    ? 'يحدّ التحميلات والخيوط ويفرض الواجهة الكلاسيكية'
                    : 'Limits downloads/threads and forces Classic UI',
                value: settings.batterySaverMode,
                onChanged: (val) async {
                  if (val) {
                    final confirmed = await DmxConfirmDialog.show(
                      context,
                      title: isRtl
                          ? 'تفعيل وضع توفير البطارية؟'
                          : 'Enable Battery Saver?',
                      message: isRtl
                          ? 'سيحدّ التحميلات بـ 1 والخيوط بـ 2 ويفرض الواجهة الكلاسيكية.'
                          : 'This limits downloads to 1, threads to 2, and forces Classic UI.',
                      confirmLabel: isRtl ? 'تفعيل' : 'Enable',
                      cancelLabel: isRtl ? 'إلغاء' : 'Cancel',
                    );
                    if (confirmed != true) return;
                  }
                  settings.setBatterySaverMode(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl
                    ? 'خنق السرعة حسب الطاقة'
                    : 'Power bandwidth throttling',
                subtitle: isRtl
                    ? 'تخفيض الإنتاجية على البطارية المنخفضة'
                    : 'Throttle throughput on low battery to conserve energy',
                value: settings.powerBandwidthThrottling,
                onChanged: (val) {
                  settings.setPowerBandwidthThrottling(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl
                    ? 'التحميل أثناء الشحن فقط'
                    : 'Download only while charging',
                subtitle: isRtl
                    ? 'إيقاف التحميلات مؤقتاً عند فصل الشاحن'
                    : 'Pause downloads when unplugged from power',
                value: settings.downloadOnlyWhileCharging,
                onChanged: (val) {
                  settings.setDownloadOnlyWhileCharging(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl
                    ? 'إيقاف تحميلات الخلفية على الخلوي'
                    : 'Pause background on cellular',
                subtitle: isRtl
                    ? 'عدم التحميل في الخلفية على بيانات الجوال'
                    : 'Do not download in the background over mobile data',
                value: settings.pauseOnCellular,
                onChanged: (val) {
                  settings.setPauseOnCellular(val);
                  triggerHaptic(settings);
                },
              ),
              if (!kIsWeb && Platform.isAndroid)
                ActionSettingTile(
                  accentColor: accent,
                  title: isRtl
                      ? 'تجاهل تحسينات البطارية'
                      : 'Ignore battery optimizations',
                  subtitle: isRtl
                      ? 'مطلوب لإبقاء التحميلات الطويلة حية في الخلفية'
                      : 'Needed to keep long background downloads alive',
                  buttonText: isRtl ? 'منح' : 'Grant',
                  onTap: () async {
                    await PowerMonitor.requestIgnoreBatteryOptimizations();
                    await settings.setBatteryOptimizationPrompted(true);
                    triggerHaptic(settings);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(isRtl
                              ? 'تم فتح إعدادات تحسين البطارية'
                              : 'Opened battery optimization settings'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Builds the discrete thread-count options, always including the currently
  /// stored value so the dropdown never asserts on a legacy value.
  List<int> _threadItems(int current) {
    final set = <int>{1, 2, 4, 8, 12, 16, current};
    final list = set.toList()..sort();
    return list;
  }

  Widget _buildProfileSelector(
    BuildContext context,
    SettingsProvider settings,
    Color accent,
    bool isDark,
    bool isRtl,
    DeviceCapabilities caps,
  ) {
    final active = _activeProfile(settings);
    Widget chip(_PerfProfile p, String label, IconData icon) {
      final selected = active == p;
      return ChoiceChip(
        avatar: Icon(
          icon,
          size: 16,
          color: selected ? accent : (isDark ? Colors.white70 : Colors.black54),
        ),
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        selectedColor: accent.withAlpha(50),
        backgroundColor:
            isDark ? Colors.white.withAlpha(12) : Colors.black.withAlpha(10),
        side: BorderSide(
          color: selected ? accent : Colors.transparent,
          width: 1.2,
        ),
        labelStyle: TextStyle(
          fontSize: 12.5,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected
              ? (isDark ? Colors.white : Colors.black87)
              : (isDark ? Colors.white70 : Colors.black54),
        ),
        onSelected: (_) {
          _applyProfile(settings, p, caps);
          triggerHaptic(settings);
        },
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              chip(
                  _PerfProfile.saver,
                  isRtl ? 'توفير البطارية' : 'Battery Saver',
                  Icons.battery_saver),
              chip(_PerfProfile.balanced, isRtl ? 'متوازن' : 'Balanced',
                  Icons.balance),
              chip(_PerfProfile.high, isRtl ? 'أداء عالٍ' : 'High Performance',
                  Icons.rocket_launch),
              chip(_PerfProfile.auto, isRtl ? 'تلقائي' : 'Auto',
                  Icons.auto_mode),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0),
            child: Text(
              isRtl
                  ? 'تلقائي يتكيّف مع فئة الجهاز (${caps.tier.name}) والحرارة'
                  : 'Auto adapts to device tier (${caps.tier.name}) + thermal',
              style: TextStyle(
                fontSize: 11.5,
                color: isDark ? Colors.white54 : Colors.black45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Best-effort detection of the active profile for highlighting. Battery
  /// Saver is authoritative; High Performance matches its distinctive signature;
  /// otherwise no chip is highlighted (presets are one-tap apply actions).
  _PerfProfile? _activeProfile(SettingsProvider s) {
    if (s.batterySaverMode) return _PerfProfile.saver;
    if (!s.powerAwareIsolatePool &&
        s.configuredDefaultThreadCount >= 16 &&
        !s.powerBandwidthThrottling) {
      return _PerfProfile.high;
    }
    return null;
  }

  Future<void> _applyProfile(
    SettingsProvider s,
    _PerfProfile p,
    DeviceCapabilities caps,
  ) async {
    switch (p) {
      case _PerfProfile.saver:
        await s.setBatterySaverMode(true);
        await s.setVisualQuality(VisualQuality.lite);
        await s.setImageCacheSizeMb(0);
        await s.setPowerAwareIsolatePool(true);
        await s.setPowerBandwidthThrottling(true);
        break;
      case _PerfProfile.balanced:
        await s.setBatterySaverMode(false);
        await s.setVisualQuality(VisualQuality.full);
        await s.setImageCacheSizeMb(0);
        await s.setDefaultThreadCount(8);
        await s.setPowerAwareIsolatePool(true);
        await s.setPowerBandwidthThrottling(true);
        break;
      case _PerfProfile.high:
        await s.setBatterySaverMode(false);
        await s.setVisualQuality(VisualQuality.full);
        await s.setDefaultThreadCount(16);
        await s.setPowerAwareIsolatePool(false);
        await s.setPowerBandwidthThrottling(false);
        await s.setImageCacheSizeMb(
            (caps.recommendedImageCacheMb * 2).clamp(30, 256));
        break;
      case _PerfProfile.auto:
        await s.setBatterySaverMode(false);
        await s.setImageCacheSizeMb(0);
        await s.setPowerAwareIsolatePool(true);
        await s.setThermalThreadLimiting(true);
        await s.setAutoReduceEffectsOnJank(true);
        break;
    }
  }
}

/// Image-cache slider that tracks the drag locally (so the thumb follows the
/// finger without persisting on every tick) and commits the value to
/// [SettingsProvider.setImageCacheSizeMb] on release. A value of 0 (Auto) is
/// shown when the user has not pinned an explicit size.
class _ImageCacheSlider extends StatefulWidget {
  final Color accentColor;
  final bool isRtl;

  const _ImageCacheSlider({required this.accentColor, required this.isRtl});

  @override
  State<_ImageCacheSlider> createState() => _ImageCacheSliderState();
}

class _ImageCacheSliderState extends State<_ImageCacheSlider> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final caps = DeviceTierService.current;
    final stored = settings.imageCacheSizeMb;
    final base =
        (stored > 0 ? stored : caps.recommendedImageCacheMb).clamp(30, 256);
    final value = _dragValue ?? base.toDouble();
    final label = _dragValue != null
        ? '${_dragValue!.round()} MB'
        : (stored > 0
            ? '$stored MB'
            : (widget.isRtl
                ? 'تلقائي (${caps.recommendedImageCacheMb} MB)'
                : 'Auto (${caps.recommendedImageCacheMb} MB)'));

    return SliderTile(
      accentColor: widget.accentColor,
      title: widget.isRtl ? 'ذاكرة الصور المؤقتة' : 'Image cache',
      valueLabel: label,
      subtitle: widget.isRtl
          ? 'اسحب لتثبيت الحجم — ملف "تلقائي" يعيده لتقدير الجهاز'
          : 'Drag to pin a size — the Auto profile restores device sizing',
      value: value,
      min: 30,
      max: 256,
      divisions: 226,
      onChanged: (v) => setState(() => _dragValue = v),
      onChangeEnd: (v) {
        setState(() => _dragValue = null);
        context.read<SettingsProvider>().setImageCacheSizeMb(v.round());
      },
    );
  }
}
