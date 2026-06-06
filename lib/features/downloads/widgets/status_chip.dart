import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../../core/app_theme.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';

class StatusChip extends StatelessWidget {
  final DownloadStatus status;

  const StatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<SettingsProvider>(context).isDarkMode;

    Color color;
    String label;

    switch (status) {
      case DownloadStatus.queued:
        color = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
        label = 'QUEUED';
        break;
      case DownloadStatus.downloading:
        color = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
        label = 'DOWNLOADING';
        break;
      case DownloadStatus.paused:
        color = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
        label = 'PAUSED';
        break;
      case DownloadStatus.completed:
        color = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
        label = 'COMPLETED';
        break;
      case DownloadStatus.failed:
        color = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
        label = 'FAILED';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}
