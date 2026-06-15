import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../../core/app_theme.dart';
import '../../settings/provider/settings_provider.dart';
import '../provider/download_provider.dart';
import '../../../../shared/widgets/glass_card.dart';
import '../../../../core/utils/haptic_helper.dart';
import '../../../../core/utils/localization.dart';

class DownloadStatsPanel extends StatelessWidget with HapticHelper {
  const DownloadStatsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DownloadProvider>(context);
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;

    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final dividerClr = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;

    final hasActive = provider.downloadingTasksCount > 0 || provider.queuedTasksCount > 0;
    final isRtl = L10n.isRtl(context);
    final tooltipMsg = hasActive
        ? (isRtl ? 'إيقاف مؤقت للكل' : 'PAUSE ALL')
        : (isRtl ? 'استئناف الكل' : 'RESUME ALL');

    return GlassCard(
      borderRadius: 20,
      padding: const EdgeInsets.all(18),
      isDarkMode: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Total Speed Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'TOTAL DOWNLOAD SPEED',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: secClr,
                      fontSize: 10,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    provider.currentDownloadSpeedFormatted,
                    style: Theme.of(context).textTheme.displayMedium?.copyWith(
                      fontSize: 24,
                      color: blueClr,
                      letterSpacing: -0.5,
                      shadows: isDark
                          ? [
                              Shadow(
                                color: blueClr.withValues(alpha: 0.35),
                                blurRadius: 10.0,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ],
              ),
              // Sensor / Signal Icon (Toggles Start/Stop All)
              Material(
                color: Colors.transparent,
                child: Tooltip(
                  message: tooltipMsg,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      triggerHaptic(settings);
                      provider.toggleStartStopAll();
                    },
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: (hasActive ? redClr : greenClr).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: (hasActive ? redClr : greenClr).withValues(alpha: 0.15),
                          width: 0.8,
                        ),
                      ),
                      child: Icon(
                        hasActive ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: hasActive ? redClr : greenClr,
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
          // Row of counts
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStatItem(
                context,
                title: 'ACTIVE',
                value: provider.downloadingTasksCount.toString(),
                color: blueClr,
                isDark: isDark,
              ),
              _buildDivider(isDark),
              _buildStatItem(
                context,
                title: 'QUEUED',
                value: provider.queuedTasksCount.toString(),
                color: violetClr,
                isDark: isDark,
              ),
              _buildDivider(isDark),
              _buildStatItem(
                context,
                title: 'COMPLETED',
                value: provider.completedTasksCount.toString(),
                color: greenClr,
                isDark: isDark,
              ),
              _buildDivider(isDark),
              _buildStatItem(
                context,
                title: 'FAILED',
                value: (provider.failedTasksCount + provider.pausedTasksCount)
                    .toString(),
                color: redClr,
                isDark: isDark,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDivider(bool isDark) {
    return Container(
      width: 1,
      height: 30,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
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
    return Column(
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
            fontSize: 9,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: Theme.of(context).textTheme.displayLarge?.copyWith(
            fontSize: 18,
            color: color,
            shadows: isDark
                ? [
                    Shadow(color: color.withValues(alpha: 0.2), blurRadius: 6.0),
                  ]
                : null,
          ),
        ),
      ],
    );
  }
}
