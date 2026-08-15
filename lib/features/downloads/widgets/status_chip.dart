import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/app_theme.dart';
import '../../../../core/utils/localization.dart';
import '../../../shared/mixins/pausable_loop_animation.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';

class StatusChip extends StatelessWidget {
  final DownloadTask task;

  const StatusChip({super.key, required this.task});

  bool _shouldPulse(DownloadTask task) {
    return task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.merging ||
        (task.status == DownloadStatus.completed &&
            task.isTorrent &&
            task.seedingEnabled);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<SettingsProvider>().isDarkMode;

    Color color;
    String label;
    final isSeeding = task.status == DownloadStatus.completed &&
        task.isTorrent &&
        task.seedingEnabled;

    if (isSeeding) {
      color = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
      label = L10n.of(context, 'status_seeding');
    } else {
      switch (task.status) {
        case DownloadStatus.queued:
          color = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
          label = L10n.of(context, 'stats_queued_short');
          break;
        case DownloadStatus.downloading:
          color = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
          label = L10n.of(context, 'stats_downloading').toUpperCase();
          break;
        case DownloadStatus.paused:
          color = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
          if (task.scheduledAt != null &&
              task.scheduledAt!.isAfter(DateTime.now())) {
            label = L10n.of(context, 'add_download_schedule').toUpperCase();
          } else if (task.errorMessage != null &&
              task.errorMessage!.contains('WiFi')) {
            label = L10n.of(context, 'status_paused_wifi');
          } else if (task.errorMessage != null &&
              task.errorMessage!.contains('Network')) {
            label = L10n.of(context, 'status_paused_offline');
          } else {
            label = L10n.of(context, 'stats_paused_short');
          }
          break;
        case DownloadStatus.completed:
          color = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
          label = L10n.of(context, 'stats_completed_short');
          break;
        case DownloadStatus.failed:
          color = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
          label = L10n.of(context, 'stats_failed_short');
          break;
        case DownloadStatus.merging:
          color = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
          label = 'MERGING';
          break;
      }
    }

    final isPulsing = _shouldPulse(task) && modernAnimationsAllowed(context);
    final textWidget = Text(
      label,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: color,
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
    );

    if (!isPulsing) {
      return RepaintBoundary(
        child: _buildChipContent(
          context,
          color: color,
          pulseValue: 1.0,
          isPulsing: false,
          child: textWidget,
        ),
      );
    }

    return RepaintBoundary(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.4, end: 1.0),
        duration: const Duration(milliseconds: 1500),
        curve: Curves.easeInOut,
        builder: (context, value, child) {
          return _buildChipContent(
            context,
            color: color,
            pulseValue: value,
            isPulsing: true,
            child: child!,
          );
        },
        child: textWidget,
      ),
    );
  }

  Widget _buildChipContent(
    BuildContext context, {
    required Color color,
    required double pulseValue,
    required bool isPulsing,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withValues(alpha: isPulsing ? 0.45 * pulseValue : 0.3),
          width: 0.8,
        ),
      ),
      child: child,
    );
  }
}
