import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../../core/app_theme.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';

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
        (task.status == DownloadStatus.completed && task.isTorrent && task.seedingEnabled);
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
    final isDark = context.read<SettingsProvider>().isDarkMode;

    Color color;
    String label;
    final task = widget.task;
    final isSeeding = task.status == DownloadStatus.completed && task.isTorrent && task.seedingEnabled;

    if (isSeeding) {
      color = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
      label = 'SEEDING';
    } else {
      switch (task.status) {
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
    }

    final isPulseActive = _shouldPulse(task) && _pulseAnimation != null;

    final chipContent = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: isPulseActive
          ? BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: color.withValues(alpha: 0.45 * _pulseAnimation!.value),
                width: 0.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.08 * _pulseAnimation!.value),
                  blurRadius: 6.0,
                  spreadRadius: 0.5,
                ),
              ],
            )
          : BoxDecoration(
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

    if (isPulseActive) {
      return AnimatedBuilder(
        animation: _pulseAnimation!,
        child: chipContent,
        builder: (context, child) {
          final pulse = _pulseAnimation!.value;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: color.withValues(alpha: 0.45 * pulse),
                width: 0.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.08 * pulse),
                  blurRadius: 6.0,
                  spreadRadius: 0.5,
                ),
              ],
            ),
            child: child,
          );
        },
      );
    }

    return chipContent;
  }
}
