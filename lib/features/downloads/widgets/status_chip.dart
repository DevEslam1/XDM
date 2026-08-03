import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../../core/app_theme.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';
import '../../../../core/utils/localization.dart';

class StatusChip extends StatefulWidget {
  final DownloadTask task;

  const StatusChip({super.key, required this.task});

  @override
  State<StatusChip> createState() => _StatusChipState();
}

class _StatusChipState extends State<StatusChip> with TickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _pulseAnimation;

  bool _shouldPulse(DownloadTask task) {
    return task.status == DownloadStatus.downloading ||
        (task.status == DownloadStatus.completed &&
            task.isTorrent &&
            task.seedingEnabled);
  }

  @override
  void initState() {
    super.initState();
    if (_shouldPulse(widget.task)) {
      _startPulse();
    }
  }

  @override
  void didUpdateWidget(StatusChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shouldPulse(widget.task)) {
      _startPulse();
    } else {
      _stopPulse();
    }
  }

  void _startPulse() {
    if (_controller == null) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1500),
      );
      _pulseAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
        CurvedAnimation(
          parent: _controller!,
          curve: Curves.easeInOut,
        ),
      );
      _controller!.repeat(reverse: true);
    }
  }

  void _stopPulse() {
    _controller?.dispose();
    _controller = null;
    _pulseAnimation = null;
  }

  @override
  void dispose() {
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<SettingsProvider>().isDarkMode;

    Color color;
    String label;
    final task = widget.task;
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
          color = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
          label = L10n.of(context, 'stats_downloading').toUpperCase();
          break;
        case DownloadStatus.paused:
          color = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
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
      }
    }

    final isPulseActive = _shouldPulse(task) && _pulseAnimation != null;
    final textWidget = Text(
      label,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: color,
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
    );

    if (isPulseActive) {
      return AnimatedBuilder(
        animation: _pulseAnimation!,
        child: textWidget,
        builder: (context, child) {
          return _buildChipContent(
            context,
            color: color,
            label: label,
            pulseValue: _pulseAnimation!.value,
            isPulsing: true,
            textWidget: child,
          );
        },
      );
    }

    return _buildChipContent(
      context,
      color: color,
      label: label,
      pulseValue: 1.0,
      isPulsing: false,
      textWidget: textWidget,
    );
  }

  Widget _buildChipContent(
    BuildContext context, {
    required Color color,
    required String label,
    required double pulseValue,
    required bool isPulsing,
    Widget? textWidget,
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
        boxShadow: isPulsing
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.08 * pulseValue),
                  blurRadius: 6.0,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
      child: textWidget ??
          Text(
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
