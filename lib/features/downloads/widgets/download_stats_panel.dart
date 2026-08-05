import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../../core/app_theme.dart';
import '../../settings/provider/settings_provider.dart';
import '../provider/download_provider.dart';
import '../../../../core/utils/haptic_helper.dart';
import '../../../../core/utils/localization.dart';
import '../../../../shared/design/dmx_design.dart';

import 'filter_chips_bar.dart';

class DownloadStatsPanel extends StatelessWidget with HapticHelper {
  const DownloadStatsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<SettingsProvider, ({bool isDark, bool classicUi})>(
      selector: (_, settings) =>
          (isDark: settings.isDarkMode, classicUi: settings.classicUi),
      builder: (context, settingsState, _) {
        final isDark = settingsState.isDark;
        final provider = context.watch<DownloadProvider>();
        final blueClr = getActiveFilterColor(provider, isDark);
        final violetClr =
            isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
        final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
        final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
        final amberClr = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
        final secClr =
            isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
        final dividerClr =
            isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;

        return DmxCardShell(
          accent: blueClr,
          showRail: false,
          radius: 20,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Selector<DownloadProvider, _StatsData>(
                selector: (_, p) => _StatsData(
                  speed: p.currentDownloadSpeedFormatted,
                  active: p.downloadingTasksCount,
                  queued: p.queuedTasksCount,
                  completed: p.completedTasksCount,
                  failed: p.failedTasksCount,
                  paused: p.pausedTasksCount,
                  hasActive:
                      p.downloadingTasksCount > 0 || p.queuedTasksCount > 0,
                ),
                builder: (context, data, _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                L10n.of(context, 'stats_total_speed'),
                                style: Theme.of(context)
                                    .textTheme
                                    .labelMedium
                                    ?.copyWith(
                                      color: secClr,
                                      fontSize: 10,
                                      letterSpacing: 1.0,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                data.speed,
                                style: Theme.of(context)
                                    .textTheme
                                    .displayMedium
                                    ?.copyWith(
                                      fontSize: 24,
                                      color: blueClr,
                                      letterSpacing: -0.5,
                                    ),
                              ),
                            ],
                          ),
                          Material(
                            color: Colors.transparent,
                            child: Tooltip(
                              message: data.hasActive
                                  ? L10n.of(context, 'pause_all_btn')
                                  : L10n.of(context, 'resume_all_btn'),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () {
                                  triggerHaptic(
                                      context.read<SettingsProvider>());
                                  context
                                      .read<DownloadProvider>()
                                      .toggleStartStopAll();
                                },
                                child: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: (data.hasActive ? redClr : greenClr)
                                        .withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color:
                                          (data.hasActive ? redClr : greenClr)
                                              .withValues(alpha: 0.15),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Icon(
                                    data.hasActive
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    color: data.hasActive ? redClr : greenClr,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Divider(color: dividerClr, height: 1.0),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          Expanded(
                              child: _buildStatItem(context,
                                  title: L10n.of(context, 'stats_active_short'),
                                  value: '${data.active}',
                                  color: blueClr,
                                  isDark: isDark)),
                          _buildDivider(isDark),
                          Expanded(
                              child: _buildStatItem(context,
                                  title: L10n.of(context, 'stats_queued_short'),
                                  value: '${data.queued}',
                                  color: violetClr,
                                  isDark: isDark)),
                          _buildDivider(isDark),
                          Expanded(
                              child: _buildStatItem(context,
                                  title:
                                      L10n.of(context, 'stats_completed_short'),
                                  value: '${data.completed}',
                                  color: greenClr,
                                  isDark: isDark)),
                          _buildDivider(isDark),
                          Expanded(
                              child: _buildStatItem(context,
                                  title: L10n.of(context, 'stats_paused_short'),
                                  value: '${data.paused}',
                                  color: amberClr,
                                  isDark: isDark)),
                          _buildDivider(isDark),
                          Expanded(
                              child: _buildStatItem(context,
                                  title: L10n.of(context, 'stats_failed_short'),
                                  value: '${data.failed}',
                                  color: redClr,
                                  isDark: isDark)),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),);
      },
    );
  }

  Widget _buildDivider(bool isDark) {
    return Container(
      width: 1,
      height: 24,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }

  Widget _buildStatItem(
    BuildContext context, {
    required String title,
    required String value,
    required Color color,
    required bool isDark,
  }) {
    final isZero = value == '0';
    final primaryClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final labelClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return Column(
      children: [
        Text(
          title,
          style: TextStyle(
            color: labelClr,
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            fontFamily: 'Space Grotesk',
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isZero ? mutedClr.withValues(alpha: 0.4) : color,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              value,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                fontFamily: 'Space Grotesk',
                color: isZero ? mutedClr : primaryClr,
              ),
            ),
          ],
        ),
      ],
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
  final bool hasActive;

  const _StatsData({
    required this.speed,
    required this.active,
    required this.queued,
    required this.completed,
    required this.failed,
    required this.paused,
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
          hasActive == other.hasActive;

  @override
  int get hashCode =>
      Object.hash(speed, active, queued, completed, failed, paused, hasActive);
}
