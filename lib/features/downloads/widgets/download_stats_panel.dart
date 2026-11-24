import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/utils/haptic_helper.dart';
import '../../../../core/utils/localization.dart';
import '../../../../shared/design/dmx_design.dart';
import '../../../../shared/design/dmx_tokens.dart';
import '../../settings/provider/settings_provider.dart';
import '../provider/download_provider.dart';
import 'filter_chips_bar.dart';

class DownloadStatsPanel extends StatelessWidget with HapticHelper {
  const DownloadStatsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Selector<SettingsProvider, ({bool isDark, bool classicUi})>(
        selector: (_, settings) =>
            (isDark: settings.isDarkMode, classicUi: settings.classicUi),
        builder: (context, settingsState, _) {
          final isDark = settingsState.isDark;
          final provider = context.read<DownloadProvider>();
          final accentClr = getActiveFilterColor(provider, isDark);
          final violetClr =
              isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
          final greenClr =
              isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
          final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
          final amberClr =
              isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
          final secClr =
              isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
          final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
          final dividerClr =
              isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle;

          return DmxCardShell(
            accent: accentClr,
            showRail: false,
            radius: DmxTokens.radiusXl,
            child: Padding(
              padding: const EdgeInsets.all(DmxTokens.spaceLg),
              child: Selector<DownloadProvider, _StatsData>(
                selector: (_, p) => _StatsData(
                  speed: p.currentDownloadSpeedFormatted,
                  active: p.downloadingTasksCount,
                  queued: p.queuedTasksCount,
                  completed: p.completedTasksCount,
                  failed: p.failedTasksCount,
                  paused: p.pausedTasksCount,
                  totalBytes: p.totalDownloadedBytes,
                  hasActive:
                      p.downloadingTasksCount > 0 || p.queuedTasksCount > 0,
                ),
                builder: (context, data, _) {
                  final healthColor = data.failed > 0
                      ? redClr
                      : (data.hasActive ? greenClr : mutedClr);
                  final healthLabel = data.failed > 0
                      ? '${data.failed} ${L10n.of(context, 'stats_failed_short')}'
                      : (data.hasActive
                          ? L10n.of(context, 'stats_active_short')
                          : 'IDLE');

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Top telemetry row: Aggregate speed + Total data + Health + Action
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      L10n.of(context, 'stats_total_speed')
                                          .toUpperCase(),
                                      style: TextStyle(
                                        color: secClr,
                                        fontFamily: 'Space Grotesk',
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.0,
                                      ),
                                    ),
                                    const SizedBox(width: DmxTokens.spaceSm),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color:
                                            healthColor.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(
                                          DmxTokens.radiusFull,
                                        ),
                                        border: Border.all(
                                          color: healthColor.withValues(
                                            alpha: 0.28,
                                          ),
                                          width: 0.7,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            width: 5,
                                            height: 5,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: healthColor,
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            healthLabel.toUpperCase(),
                                            style: TextStyle(
                                              color: healthColor,
                                              fontFamily: 'Space Grotesk',
                                              fontSize: 9,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    Flexible(
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: AlignmentDirectional
                                            .centerStart,
                                        child: Text(
                                          data.speed,
                                          style: Theme.of(context)
                                              .textTheme
                                              .displayMedium
                                              ?.copyWith(
                                                fontSize: 24,
                                                fontWeight: FontWeight.w800,
                                                color: accentClr,
                                                letterSpacing: -0.5,
                                                fontFeatures: const [
                                                  FontFeature.tabularFigures(),
                                                ],
                                              ),
                                        ),
                                      ),
                                    ),
                                    if (data.totalBytes > 0) ...[
                                      const SizedBox(width: 10),
                                      Flexible(
                                        child: Text(
                                          formatBytes(
                                            data.totalBytes.toDouble(),
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppTheme.dataStyle(
                                            isDark: isDark,
                                            size: 11.5,
                                            weight: FontWeight.w600,
                                            color: secClr,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: DmxTokens.spaceMd),
                          _ToggleAllActionButton(
                            hasActive: data.hasActive,
                            activeColor: redClr,
                            idleColor: greenClr,
                            onTap: () {
                              triggerHaptic(context.read<SettingsProvider>());
                              context
                                  .read<DownloadProvider>()
                                  .toggleStartStopAll();
                            },
                          ),
                        ],
                      ),

                      const SizedBox(height: 14),
                      Divider(color: dividerClr, height: 1.0),
                      const SizedBox(height: 12),

                      // Compact telemetry metric chips row
                      Row(
                        children: [
                          Expanded(
                            child: _MetricTile(
                              title: L10n.of(context, 'stats_active_short'),
                              value: '${data.active}',
                              color: accentClr,
                              isDark: isDark,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _MetricTile(
                              title: L10n.of(context, 'stats_queued_short'),
                              value: '${data.queued}',
                              color: violetClr,
                              isDark: isDark,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _MetricTile(
                              title: L10n.of(context, 'stats_completed_short'),
                              value: '${data.completed}',
                              color: greenClr,
                              isDark: isDark,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _MetricTile(
                              title: L10n.of(context, 'stats_paused_short'),
                              value: '${data.paused}',
                              color: amberClr,
                              isDark: isDark,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _MetricTile(
                              title: L10n.of(context, 'stats_failed_short'),
                              value: '${data.failed}',
                              color: redClr,
                              isDark: isDark,
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ToggleAllActionButton extends StatelessWidget {
  final bool hasActive;
  final Color activeColor;
  final Color idleColor;
  final VoidCallback onTap;

  const _ToggleAllActionButton({
    required this.hasActive,
    required this.activeColor,
    required this.idleColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = hasActive ? activeColor : idleColor;
    final label = hasActive
        ? L10n.of(context, 'pause_all_btn')
        : L10n.of(context, 'resume_all_btn');

    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: color.withValues(alpha: 0.28),
                  width: 0.9,
                ),
              ),
              child: Icon(
                hasActive ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: color,
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String title;
  final String value;
  final Color color;
  final bool isDark;

  const _MetricTile({
    required this.title,
    required this.value,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final isZero = value == '0';
    final primaryClr =
        isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final labelClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    final tileBg = isZero
        ? (isDark
            ? Colors.white.withValues(alpha: 0.03)
            : Colors.black.withValues(alpha: 0.025))
        : color.withValues(alpha: isDark ? 0.10 : 0.08);
    final tileBorder = isZero
        ? (isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle)
        : color.withValues(alpha: isDark ? 0.25 : 0.22);

    return Semantics(
      container: true,
      label: '$title: $value',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        decoration: BoxDecoration(
          color: tileBg,
          borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
          border: Border.all(color: tileBorder, width: 0.7),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isZero ? mutedClr.withValues(alpha: 0.45) : color,
                  ),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      value,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        fontFamily: 'Space Grotesk',
                        color: isZero ? mutedClr : primaryClr,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              title,
              style: TextStyle(
                color: isZero ? mutedClr : labelClr,
                fontSize: 9,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
                fontFamily: 'Space Grotesk',
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsData {
  final String speed;
  final int active;
  final int queued;
  final int completed;
  final int failed;
  final int paused;
  final int totalBytes;
  final bool hasActive;

  const _StatsData({
    required this.speed,
    required this.active,
    required this.queued,
    required this.completed,
    required this.failed,
    required this.paused,
    required this.totalBytes,
    required this.hasActive,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _StatsData &&
          runtimeType == other.runtimeType &&
          speed == other.speed &&
          active == other.active &&
          queued == other.queued &&
          completed == other.completed &&
          failed == other.failed &&
          paused == other.paused &&
          totalBytes == other.totalBytes &&
          hasActive == other.hasActive;

  @override
  int get hashCode => Object.hash(
        speed,
        active,
        queued,
        completed,
        failed,
        paused,
        totalBytes,
        hasActive,
      );
}
