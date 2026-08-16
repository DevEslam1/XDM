import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/performance_monitor.dart';
import '../../../core/services/power_monitor.dart';
import '../../../core/utils/localization.dart';
import '../../downloads/provider/download_provider.dart';
import '../provider/settings_provider.dart';

class SystemMonitorsCard extends StatefulWidget {
  final Color accentColor;
  final bool isDark;

  const SystemMonitorsCard({
    super.key,
    required this.accentColor,
    required this.isDark,
  });

  @override
  State<SystemMonitorsCard> createState() => _SystemMonitorsCardState();
}

class _SystemMonitorsCardState extends State<SystemMonitorsCard>
    with WidgetsBindingObserver {
  Timer? _refreshTimer;
  bool _isResumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startMonitoring();
  }

  void _startMonitoring() {
    PerformanceMonitor.instance.start();
    _resetTimer();
  }

  void _stopMonitoring() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    PerformanceMonitor.instance.stop();
  }

  void _resetTimer() {
    _refreshTimer?.cancel();
    if (!_isResumed || PowerMonitor.screenOff) {
      _stopMonitoring();
      return;
    }

    // Adaptive refresh rate to save CPU, GPU & battery:
    // - Battery saver mode or Thermal stress: Refresh every 4s
    // - Normal mode: Refresh every 2s (instead of 1s)
    final int intervalSec =
        (PowerMonitor.batterySaverMode == BatterySaverMode.aggressive ||
                PowerMonitor.throttleFactor < 0.8)
            ? 4
            : 2;

    _refreshTimer = Timer.periodic(Duration(seconds: intervalSec), (_) {
      if (mounted && _isResumed && !PowerMonitor.screenOff) {
        setState(() {});
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isResumed = state == AppLifecycleState.resumed;
    if (_isResumed) {
      _startMonitoring();
    } else {
      _stopMonitoring();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopMonitoring();
    super.dispose();
  }

  Color _getThermalColor(ThermalStatus status) {
    return switch (status) {
      ThermalStatus.none => Colors.greenAccent,
      ThermalStatus.fair => Colors.lightGreenAccent,
      ThermalStatus.moderate => Colors.amberAccent,
      ThermalStatus.severe => Colors.orangeAccent,
      ThermalStatus.critical => Colors.redAccent,
    };
  }

  IconData _getThermalIcon(ThermalStatus status) {
    return switch (status) {
      ThermalStatus.none || ThermalStatus.fair => Icons.thermostat_outlined,
      ThermalStatus.moderate => Icons.device_thermostat,
      ThermalStatus.severe ||
      ThermalStatus.critical =>
        Icons.local_fire_department,
    };
  }

  @override
  Widget build(BuildContext context) {
    final isRtl = L10n.isRtl(context);
    final settings = context.watch<SettingsProvider>();
    final isWifi = context.select<DownloadProvider, bool>(
      (p) => p.networkMonitor.hasWifiOrEthernet,
    );
    final activeDownloads = context.select<DownloadProvider, int>(
      (p) => p.downloadingTasksCount,
    );

    final batteryLevel = PowerMonitor.batteryLevel;
    final isCharging = PowerMonitor.isCharging;
    final thermal = PowerMonitor.thermal;
    final throttleFactor = PowerMonitor.throttleFactor;
    final saverMode = PowerMonitor.batterySaverMode;
    final screenOff = PowerMonitor.screenOff;

    final perf = PerformanceMonitor.instance;
    final jankPct = (perf.jankRatio * 100).toStringAsFixed(1);
    final avgBuildMs = perf.averageBuildMillis?.toStringAsFixed(1) ?? '0.0';
    final avgRasterMs = perf.averageRasterMillis?.toStringAsFixed(1) ?? '0.0';

    final cardBg = widget.isDark
        ? AppTheme.cardBg.withAlpha(220)
        : AppTheme.lightCardBg.withAlpha(240);
    final borderColor = widget.accentColor.withAlpha(80);

    final bool isBatterySaver =
        saverMode != BatterySaverMode.off || settings.classicUi;

    return Container(
      margin: const EdgeInsets.only(bottom: 16.0),
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16.0),
        border: Border.all(color: borderColor, width: 1.2),
        boxShadow: isBatterySaver
            ? null
            : [
                BoxShadow(
                  color: widget.accentColor.withAlpha(20),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(
                Icons.monitor_heart_outlined,
                color: widget.accentColor,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                isRtl ? 'مراقب النظام المباشر' : 'Live System Monitors',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: widget.isDark ? Colors.white : Colors.black87,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: widget.accentColor.withAlpha(30),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Colors.greenAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isRtl ? 'مباشر' : 'LIVE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: widget.accentColor,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Grid of monitor pills
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 400;
              final crossCount = isWide ? 3 : 2;
              final width =
                  (constraints.maxWidth - (crossCount - 1) * 8) / crossCount;

              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  // Power & Battery
                  _buildMonitorPill(
                    width: width,
                    icon: isCharging
                        ? Icons.battery_charging_full
                        : Icons.battery_std,
                    iconColor: isCharging
                        ? Colors.greenAccent
                        : (batteryLevel < 20
                            ? Colors.redAccent
                            : widget.accentColor),
                    label: isRtl ? 'البطارية' : 'Battery',
                    value:
                        '$batteryLevel% ${isCharging ? (isRtl ? '(شحن)' : '(Charging)') : ''}',
                    subValue: saverMode != BatterySaverMode.off
                        ? '${saverMode.name.toUpperCase()} SAVER'
                        : (isRtl ? 'عادي' : 'Normal'),
                  ),

                  // Thermal Status
                  _buildMonitorPill(
                    width: width,
                    icon: _getThermalIcon(thermal),
                    iconColor: _getThermalColor(thermal),
                    label: isRtl ? 'الحرارة' : 'Thermal State',
                    value: thermal.name.toUpperCase(),
                    subValue:
                        '${(throttleFactor * 100).toInt()}% ${isRtl ? 'طاقة' : 'Power Cap'}',
                  ),

                  // UI Jank / Performance
                  _buildMonitorPill(
                    width: width,
                    icon: Icons.speed,
                    iconColor: double.parse(jankPct) > 5.0
                        ? Colors.orangeAccent
                        : Colors.cyanAccent,
                    label: isRtl ? 'أداء الواجهة' : 'UI Jank Ratio',
                    value: '$jankPct%',
                    subValue: '${avgBuildMs}ms Build | ${avgRasterMs}ms Raster',
                  ),

                  // Network State
                  _buildMonitorPill(
                    width: width,
                    icon: isWifi ? Icons.wifi : Icons.signal_cellular_alt,
                    iconColor:
                        isWifi ? Colors.lightBlueAccent : Colors.amberAccent,
                    label: isRtl ? 'الشبكة' : 'Network',
                    value:
                        isWifi ? 'Wi-Fi / LAN' : (isRtl ? 'خلوي' : 'Cellular'),
                    subValue: settings.wifiOnly
                        ? (isRtl ? 'Wi-Fi فقط' : 'Wi-Fi Only')
                        : (isRtl ? 'جميع الشبكات' : 'Any Network'),
                  ),

                  // Active Downloads & Isolate Pool State
                  _buildMonitorPill(
                    width: width,
                    icon: Icons.downloading,
                    iconColor:
                        activeDownloads > 0 ? Colors.greenAccent : Colors.grey,
                    label: isRtl ? 'التحميلات النشطة' : 'Active Downloads',
                    value: '$activeDownloads ${isRtl ? 'نشط' : 'active'}',
                    subValue: screenOff
                        ? (isRtl ? 'الشاشة مغلقة' : 'Screen Off')
                        : (isRtl ? 'الشاشة تعمل' : 'Screen On'),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMonitorPill({
    required double width,
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    required String subValue,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: widget.isDark
            ? Colors.black.withAlpha(60)
            : Colors.grey.withAlpha(25),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: widget.isDark
              ? Colors.white.withAlpha(15)
              : Colors.black.withAlpha(10),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: widget.isDark ? Colors.grey[400] : Colors.grey[700],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: widget.isDark ? Colors.white : Colors.black87,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subValue,
                  style: TextStyle(
                    fontSize: 10,
                    color: iconColor.withAlpha(220),
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
