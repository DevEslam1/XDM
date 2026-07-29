import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/torrent_service.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/file_opener.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../settings/provider/settings_provider.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../details/screens/details_screen.dart';

/// Adaptive download card. Detects the download kind and renders a
/// purpose-built variant:
///   • Torrent / magnet  -> _TorrentCard  (seeds/peers, per-file %, seeding)
///   • Media / playlist  -> _MediaCard    (quality badge, audio track, merge)
///   • Single file       -> _FileCard     (chunked multi-thread progress)
///
/// Every variant exposes the same telemetry strip:
///   DOWNLOADED / TOTAL SIZE / ELAPSED / TIME REMAINING / SPEED
/// plus a chunked progress bar and the total percentage readout.
class DownloadCard extends StatelessWidget with HapticHelper {
  final DownloadTask task;
  final bool compact;

  const DownloadCard({super.key, required this.task, this.compact = false});

  @override
  Widget build(BuildContext context) {
    if (task.isTorrent) {
      return _TorrentCard(task: task, compact: compact);
    }
    if (task.youtubeQualityPreset != null || task.mergedAudioUrl != null) {
      return _MediaCard(task: task, compact: compact);
    }
    return _FileCard(task: task, compact: compact);
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ────────────────────────────────────────────────────────────────────────────

Color _statusColor(DownloadStatus status, bool isDark) {
  return switch (status) {
    DownloadStatus.queued =>
      isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
    DownloadStatus.downloading =>
      isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
    DownloadStatus.paused =>
      isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
    DownloadStatus.completed =>
      isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
    DownloadStatus.failed => isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
  };
}

IconData _categoryIcon(String category) {
  return switch (category) {
    'Video' => Icons.movie_outlined,
    'Audio' => Icons.audiotrack_outlined,
    'Document' => Icons.description_outlined,
    'Archive' => Icons.folder_zip_outlined,
    'APK' => Icons.android_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

bool _isSeeding(DownloadTask task) =>
    task.status == DownloadStatus.completed &&
    task.isTorrent &&
    task.seedingEnabled;

// ────────────────────────────────────────────────────────────────────────────
// Card shell — status accent rail + tinted panel
// ────────────────────────────────────────────────────────────────────────────

class _CardShell extends StatelessWidget {
  final Widget child;
  final Color accent;
  final bool isDark;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _CardShell({
    required this.child,
    required this.accent,
    required this.isDark,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          decoration: AppTheme.panel(
            isDark: isDark,
            radius: 22,
            accentColor: accent,
            accentAlpha: 0.22,
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // status accent rail
                Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(22),
                      bottomLeft: Radius.circular(22),
                    ),
                    boxShadow: [
                      AppTheme.glow(accent, alpha: 0.30, blur: 6, spread: 0),
                    ],
                  ),
                ),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Status chip — pulses while downloading / seeding
// ────────────────────────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final DownloadTask task;
  final bool isDark;
  final String? overrideLabel;

  const _StatusChip({
    required this.task,
    required this.isDark,
    this.overrideLabel,
  });

  IconData get _icon {
    if (_isSeeding(task)) return Icons.cloud_upload;
    return switch (task.status) {
      DownloadStatus.queued => Icons.hourglass_empty,
      DownloadStatus.downloading => Icons.downloading,
      DownloadStatus.paused => Icons.pause_circle,
      DownloadStatus.completed => Icons.check_circle,
      DownloadStatus.failed => Icons.error,
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(task.status, isDark);
    final label =
        overrideLabel ?? L10n.translateStatusName(context, task.status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: AppTheme.chipDecoration(
        color: color,
        isDark: isDark,
        radius: 12,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _TelemetryStrip extends StatelessWidget {
  final DownloadTask task;
  final bool isDark;
  final Color accent;
  final double seedingUploadSpeed;

  const _TelemetryStrip({
    required this.task,
    required this.isDark,
    required this.accent,
    this.seedingUploadSpeed = 0,
  });

  @override
  Widget build(BuildContext context) {
    final seeding = _isSeeding(task);

    final String etaText;
    if (task.status == DownloadStatus.downloading) {
      etaText = task.etaFormatted;
    } else if (task.status == DownloadStatus.completed) {
      etaText = 'DONE';
    } else {
      etaText = '--';
    }

    final String speedText;
    if (task.status == DownloadStatus.downloading) {
      speedText = task.speedFormatted;
    } else if (seeding) {
      speedText = '${formatBytes(seedingUploadSpeed)}/s';
    } else {
      speedText = '--';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Row(
            children: [
              _TelemetryTile(icon: Icons.speed, label: speedText),
              const SizedBox(width: 16),
              _TelemetryTile(icon: Icons.access_time, label: etaText),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _TelemetryTile(
                icon: Icons.storage,
                label: task.downloadedSizeFormatted,
              ),
              const SizedBox(width: 16),
              _TelemetryTile(
                icon: Icons.percent,
                label: '${(task.progress * 100).toInt()}%',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Progress — chunked bar + total percentage readout
// ────────────────────────────────────────────────────────────────────────────

class _ChunkedProgressBar extends StatelessWidget {
  final DownloadTask task;
  final bool isDark;
  final Color color;

  const _ChunkedProgressBar({
    required this.task,
    required this.isDark,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final chunks = task.chunks;
    final Widget bar;
    if (chunks.length <= 1) {
      bar = ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(
          children: [
            Container(
              height: 8,
              decoration: AppTheme.progressTrack(isDark: isDark),
            ),
            FractionallySizedBox(
              widthFactor: task.progress.clamp(0.0, 1.0),
              child: Container(
                height: 8,
                decoration: AppTheme.progressFill(color),
              ),
            ),
          ],
        ),
      );
    } else {
      bar = Row(
        children: List.generate(chunks.length, (i) {
          final p = chunks[i].clamp(0.0, 1.0);
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                left: i == 0 ? 0 : 2.5,
                right: i == chunks.length - 1 ? 0 : 2.5,
              ),
              child: Stack(
                children: [
                  Container(
                    height: 8,
                    decoration: AppTheme.progressTrack(
                      isDark: isDark,
                      radius: 3,
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: p,
                    child: Container(
                      height: 8,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      );
    }
    if (task.status == DownloadStatus.downloading) {
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.6, end: 1.0),
        duration: const Duration(milliseconds: 1500),
        builder: (context, opacity, child) {
          return Opacity(opacity: opacity, child: child);
        },
        child: bar,
      );
    }
    return bar;
  }
}

class _ProgressRow extends StatelessWidget {
  final DownloadTask task;
  final bool isDark;
  final Color color;

  const _ProgressRow({
    required this.task,
    required this.isDark,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ChunkedProgressBar(task: task, isDark: isDark, color: color),
        ),
        const SizedBox(width: 12),
        // Total percentage readout
        Text(
          task.progressPercentString,
          style: AppTheme.dataStyle(
            isDark: isDark,
            size: 15,
            weight: FontWeight.w800,
            color: color,
          ),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Control cluster — pause / resume / retry / open / delete
// (torrent pause & resume go through the same provider calls; the provider
//  now validates the native torrent handle so resume actually re-attaches)
// ────────────────────────────────────────────────────────────────────────────

class _ControlButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;
  final String tooltip;
  final bool filled;

  const _ControlButton({
    required this.icon,
    required this.color,
    required this.onPressed,
    required this.tooltip,
    this.filled = false,
  });

  @override
  State<_ControlButton> createState() => _ControlButtonState();
}

class _ControlButtonState extends State<_ControlButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _pressed ? 0.85 : 1.0,
          duration: AppTheme.motionFast,
          curve: AppTheme.motionSpring,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: widget.filled
                  ? widget.color
                  : widget.color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: widget.color.withValues(alpha: widget.filled ? 0 : 0.25),
                width: 0.8,
              ),
            ),
            child: Icon(
              widget.icon,
              size: 18,
              color: widget.filled
                  ? AppTheme.inkOn(widget.color)
                  : widget.color,
            ),
          ),
        ),
      ),
    );
  }
}

class _ControlCluster extends StatelessWidget with HapticHelper {
  final DownloadTask task;

  const _ControlCluster({required this.task});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<DownloadProvider>();
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (task.status == DownloadStatus.downloading)
          _ControlButton(
            icon: Icons.pause_rounded,
            color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
            tooltip: L10n.of(context, 'pause_btn'),
            onPressed: () {
              triggerHaptic(settings);
              provider.pauseTask(task.id);
            },
          )
        else if (task.status == DownloadStatus.paused ||
            task.status == DownloadStatus.queued)
          _ControlButton(
            icon: Icons.play_arrow_rounded,
            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            filled: true,
            tooltip: task.status == DownloadStatus.queued
                ? (isRtl ? 'بدء' : 'Start')
                : (isRtl ? 'استئناف' : 'Resume'),
            onPressed: () {
              triggerHaptic(settings);
              provider.resumeTask(task.id);
            },
          )
        else if (task.status == DownloadStatus.failed)
          _ControlButton(
            icon: Icons.refresh_rounded,
            color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
            filled: true,
            tooltip: isRtl ? 'إعادة' : 'Retry',
            onPressed: () {
              triggerHaptic(settings);
              provider.retryTask(task.id);
            },
          )
        else if (task.status == DownloadStatus.completed)
          _ControlButton(
            icon: Icons.folder_open_rounded,
            color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
            filled: true,
            tooltip: isRtl ? 'فتح الملف' : 'Open',
            onPressed: () {
              triggerHaptic(settings);
              openFile(context, task.localFilePath, settings);
            },
          ),
        const SizedBox(width: 6),
        _ControlButton(
          icon: Icons.delete_outline_rounded,
          color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
          tooltip: L10n.of(context, 'delete_btn'),
          onPressed: () async {
            triggerHaptic(settings);
            final deleteFiles = await showDeleteConfirmationDialog(
              context,
              task,
              settings,
            );
            if (deleteFiles != null) {
              provider.deleteTask(task.id, deleteFiles: deleteFiles);
              if (context.mounted) {
                ThemedSnackbar.show(
                  context,
                  message: isRtl ? 'تم حذف التحميل بنجاح' : 'Download deleted',
                  color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                  icon: Icons.delete_outline,
                  isDarkMode: isDark,
                );
              }
            }
          },
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Status message / error rows
// ────────────────────────────────────────────────────────────────────────────

class _NoticeRow extends StatelessWidget {
  final String text;
  final Color color;
  final IconData icon;
  final bool isDark;

  const _NoticeRow({
    required this.text,
    required this.color,
    required this.icon,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 0.8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: AppTheme.dataStyle(
                isDark: isDark,
                size: 10,
                weight: FontWeight.w600,
                color: color,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Variant 1 — Single file
// ────────────────────────────────────────────────────────────────────────────

class _FileCard extends StatelessWidget with HapticHelper {
  final DownloadTask task;
  final bool compact;

  const _FileCard({required this.task, required this.compact});

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final statusColor = _statusColor(task.status, isDark);
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return _CardShell(
      accent: statusColor,
      isDark: isDark,
      onTap: () {
        triggerHaptic(settings);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => DetailsScreen(taskId: task.id)),
        );
      },
      onLongPress: () => _showAdvancedControls(context, task, settings),
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: compact ? 38 : 44,
                  height: compact ? 38 : 44,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.15),
                      width: 0.8,
                    ),
                  ),
                  child: Icon(
                    _categoryIcon(task.category),
                    color: statusColor,
                    size: compact ? 18 : 21,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.fileName,
                        style: AppTheme.dataStyle(
                          isDark: isDark,
                          size: compact ? 13 : 14,
                          weight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          _StatusChip(task: task, isDark: isDark),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              L10n.translateCategory(
                                context,
                                task.category,
                              ).toUpperCase(),
                              style: AppTheme.microLabel(
                                isDark: isDark,
                                size: 8.5,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                _ControlCluster(task: task),
              ],
            ),
            const SizedBox(height: 12),
            _TelemetryStrip(task: task, isDark: isDark, accent: statusColor),
            const SizedBox(height: 12),
            _ProgressRow(task: task, isDark: isDark, color: statusColor),
            if (task.statusMessage != null && task.statusMessage!.isNotEmpty)
              _NoticeRow(
                text: task.statusMessage!,
                color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
                icon: Icons.merge_type_rounded,
                isDark: isDark,
              ),
            if (task.status == DownloadStatus.failed &&
                task.errorMessage != null)
              _NoticeRow(
                text: task.errorMessage!,
                color: statusColor,
                icon: Icons.error_outline,
                isDark: isDark,
              ),
            if (task.status == DownloadStatus.downloading)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Text(
                    '${task.threadCount} CH • ${task.downloadedSizeFormatted} / ${task.sizeFormatted}',
                    style: AppTheme.microLabel(
                      isDark: isDark,
                      color: mutedClr,
                      size: 8.5,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Variant 2 — Media (single video / audio / playlist item)
// ────────────────────────────────────────────────────────────────────────────

class _MediaCard extends StatelessWidget with HapticHelper {
  final DownloadTask task;
  final bool compact;

  const _MediaCard({required this.task, required this.compact});

  String get _qualityLabel {
    final preset = task.youtubeQualityPreset ?? '';
    if (preset == 'audio_only') return 'AUDIO';
    if (preset == 'best_combined' || preset == 'best') return 'BEST';
    if (preset == 'best_muxed') return 'MP4';
    return preset.toUpperCase();
  }

  bool get _hasAudioTrack =>
      task.mergedAudioUrl != null && task.mergedAudioUrl!.isNotEmpty;

  bool get _isAudioOnly => task.youtubeQualityPreset == 'audio_only';

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final statusColor = _statusColor(task.status, isDark);
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final qualityColor = _isAudioOnly
        ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
        : (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed);

    return _CardShell(
      accent: statusColor,
      isDark: isDark,
      onTap: () {
        triggerHaptic(settings);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => DetailsScreen(taskId: task.id)),
        );
      },
      onLongPress: () => _showAdvancedControls(context, task, settings),
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: compact ? 46 : 56,
                  height: compact ? 34 : 40,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.15),
                      width: 0.8,
                    ),
                  ),
                  child: Icon(
                    _isAudioOnly
                        ? Icons.audiotrack_rounded
                        : Icons.play_arrow_rounded,
                    color: statusColor,
                    size: compact ? 18 : 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.fileName,
                        style: AppTheme.dataStyle(
                          isDark: isDark,
                          size: compact ? 13 : 14,
                          weight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          _StatusChip(task: task, isDark: isDark),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2.5,
                            ),
                            decoration: BoxDecoration(
                              color: qualityColor.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(
                                color: qualityColor.withValues(alpha: 0.3),
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              _qualityLabel,
                              style: AppTheme.microLabel(
                                isDark: isDark,
                                color: qualityColor,
                                size: 8,
                              ),
                            ),
                          ),
                          if (_hasAudioTrack && !_isAudioOnly) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.audio_file_rounded,
                              size: 12,
                              color: mutedClr,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              'A/V',
                              style: AppTheme.microLabel(
                                isDark: isDark,
                                size: 8,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                _ControlCluster(task: task),
              ],
            ),
            const SizedBox(height: 12),
            _TelemetryStrip(task: task, isDark: isDark, accent: statusColor),
            const SizedBox(height: 12),
            _ProgressRow(task: task, isDark: isDark, color: statusColor),
            // Separate audio-track progress while merging download runs
            if (_hasAudioTrack &&
                !_isAudioOnly &&
                task.status == DownloadStatus.downloading &&
                task.audioProgress > 0) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.audio_file_rounded, size: 11, color: mutedClr),
                  const SizedBox(width: 6),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: Stack(
                        children: [
                          Container(
                            height: 4,
                            decoration: AppTheme.progressTrack(
                              isDark: isDark,
                              radius: 2,
                            ),
                          ),
                          FractionallySizedBox(
                            widthFactor: task.audioProgress.clamp(0.0, 1.0),
                            child: Container(
                              height: 4,
                              decoration: BoxDecoration(
                                color: isDark
                                    ? AppTheme.neonGreen
                                    : AppTheme.lightNeonGreen,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    task.audioProgressPercentString,
                    style: AppTheme.microLabel(isDark: isDark, size: 8.5),
                  ),
                ],
              ),
            ],
            if (task.statusMessage != null && task.statusMessage!.isNotEmpty)
              _NoticeRow(
                text: task.statusMessage!,
                color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
                icon: Icons.merge_type_rounded,
                isDark: isDark,
              ),
            if (task.status == DownloadStatus.failed &&
                task.errorMessage != null)
              _NoticeRow(
                text: task.errorMessage!,
                color: statusColor,
                icon: Icons.error_outline,
                isDark: isDark,
              ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Variant 3 — Torrent / magnet
// ────────────────────────────────────────────────────────────────────────────

class _TorrentCard extends StatefulWidget {
  final DownloadTask task;
  final bool compact;

  const _TorrentCard({required this.task, required this.compact});

  @override
  State<_TorrentCard> createState() => _TorrentCardState();
}

class _TorrentCardState extends State<_TorrentCard> with HapticHelper {
  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final statusColor = _statusColor(widget.task.status, isDark);
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final isMagnet = widget.task.url.startsWith('magnet:');
    final seeding = _isSeeding(widget.task);

    return Selector<
      DownloadProvider,
      ({int seeds, int peers, double uploadSpeed})
    >(
      selector: (context, provider) => (
        seeds: provider.getTorrentSeeds(widget.task.id),
        peers: provider.getTorrentPeers(widget.task.id),
        uploadSpeed: provider.getTorrentUploadSpeed(widget.task.id),
      ),
      builder: (context, stats, _) {
        final fileCount = widget.task.torrentFiles?.length ?? 0;
        final selectedCount =
            widget.task.torrentFiles
                ?.where((f) => f['selected'] == true)
                .length ??
            0;

        return _CardShell(
          accent: statusColor,
          isDark: isDark,
          onTap: () {
            triggerHaptic(settings);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DetailsScreen(taskId: widget.task.id),
              ),
            );
          },
          onLongPress: () =>
              _showAdvancedControls(context, widget.task, settings),
          child: Padding(
            padding: EdgeInsets.all(widget.compact ? 12 : 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: widget.compact ? 38 : 44,
                      height: widget.compact ? 38 : 44,
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: statusColor.withValues(alpha: 0.15),
                          width: 0.8,
                        ),
                      ),
                      child: Icon(
                        isMagnet
                            ? Icons.link_rounded
                            : Icons.cloud_download_rounded,
                        color: statusColor,
                        size: widget.compact ? 18 : 21,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.task.fileName,
                            style: AppTheme.dataStyle(
                              isDark: isDark,
                              size: widget.compact ? 13 : 14,
                              weight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 5),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              _StatusChip(
                                task: widget.task,
                                isDark: isDark,
                                overrideLabel: seeding
                                    ? (isRtl ? 'مشاركة' : 'SEEDING')
                                    : null,
                              ),
                              _PeerChip(
                                icon: Icons.arrow_upward_rounded,
                                label: '${stats.seeds}',
                                color: greenClr,
                                isDark: isDark,
                              ),
                              _PeerChip(
                                icon: Icons.arrow_downward_rounded,
                                label: '${stats.peers}',
                                color: violetClr,
                                isDark: isDark,
                              ),
                              if (fileCount > 0)
                                _PeerChip(
                                  icon: Icons.folder_outlined,
                                  label: '$selectedCount/$fileCount',
                                  color: mutedClr,
                                  isDark: isDark,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Column(children: [_ControlCluster(task: widget.task)]),
                  ],
                ),
                const SizedBox(height: 12),
                // Telemetry: downloaded / total / elapsed / remain / speed
                _TelemetryStrip(
                  task: widget.task,
                  isDark: isDark,
                  accent: statusColor,
                  seedingUploadSpeed: stats.uploadSpeed,
                ),
                const SizedBox(height: 12),
                // Total progress + total percentage
                _ProgressRow(
                  task: widget.task,
                  isDark: isDark,
                  color: statusColor,
                ),
                // Per-file percentages (isolated rebuild via dedicated StatefulWidget)
                if (fileCount > 0) ...[
                  const SizedBox(height: 12),
                  _TorrentFileListSection(
                    task: widget.task,
                    isDark: isDark,
                    accent: statusColor,
                  ),
                ],
                // Seeding toggle once completed
                if (widget.task.status == DownloadStatus.completed) ...[
                  const SizedBox(height: 10),
                  Divider(
                    color: isDark
                        ? AppTheme.borderSubtle
                        : AppTheme.lightBorderSubtle,
                    height: 1,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        Icons.cloud_upload_outlined,
                        size: 14,
                        color: violetClr,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isRtl ? 'مشاركة التورنت' : 'Seed this torrent',
                        style: AppTheme.dataStyle(
                          isDark: isDark,
                          size: 11,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Switch(
                        value: widget.task.seedingEnabled,
                        onChanged: (val) {
                          triggerHaptic(settings);
                          context.read<DownloadProvider>().updateTaskSeeding(
                            widget.task.id,
                            enabled: val,
                          );
                        },
                        activeThumbColor: violetClr,
                      ),
                    ],
                  ),
                ],
                if (widget.task.status == DownloadStatus.failed &&
                    widget.task.errorMessage != null)
                  _NoticeRow(
                    text: widget.task.errorMessage!,
                    color: statusColor,
                    icon: Icons.error_outline,
                    isDark: isDark,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// FIX(R4): Isolated rebuild section for torrent file list
class _TorrentFileListSection extends StatefulWidget {
  final DownloadTask task;
  final bool isDark;
  final Color accent;

  const _TorrentFileListSection({
    required this.task,
    required this.isDark,
    required this.accent,
  });

  @override
  State<_TorrentFileListSection> createState() =>
      _TorrentFileListSectionState();
}

class _TorrentFileListSectionState extends State<_TorrentFileListSection>
    with HapticHelper {
  bool _showAllFiles = false;
  static const int _collapsedFileCount = 4;

  @override
  Widget build(BuildContext context) {
    final files = widget.task.torrentFiles ?? [];
    final displayFiles = files.map((f) {
      final selected = f['selected'] == true;
      final length = (f['length'] as num?)?.toInt() ?? 0;
      final downloaded = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      final effectiveDownloaded =
          widget.task.status == DownloadStatus.completed && selected
              ? length
              : downloaded;
      return {...f, 'downloadedBytes': effectiveDownloaded};
    }).toList();

    final visible = _showAllFiles
        ? displayFiles
        : displayFiles.take(_collapsedFileCount).toList();
    final hiddenCount = displayFiles.length - visible.length;
    final mutedClr =
        widget.isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'FILES • ${files.where((f) => f['selected'] == true).length}/${files.length}',
            style: AppTheme.microLabel(isDark: widget.isDark, size: 8),
          ),
        ),
        ...visible.map(
          (f) => _TorrentFileRow(
            file: f,
            isDark: widget.isDark,
            accent: widget.accent,
          ),
        ),
        if (hiddenCount > 0 || _showAllFiles)
          GestureDetector(
            onTap: () {
              triggerHaptic(context.read<SettingsProvider>());
              setState(() => _showAllFiles = !_showAllFiles);
            },
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _showAllFiles
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 14,
                    color: mutedClr,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _showAllFiles
                        ? 'SHOW LESS'
                        : '+$hiddenCount MORE FILE${hiddenCount == 1 ? '' : 'S'}',
                    style: AppTheme.microLabel(
                      isDark: widget.isDark,
                      color: mutedClr,
                      size: 8.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _PeerChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool isDark;

  const _PeerChip({
    required this.icon,
    required this.label,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: AppTheme.dataStyle(isDark: isDark, color: color, size: 9),
          ),
        ],
      ),
    );
  }
}

/// One torrent file row: name, individual progress bar, per-file percentage,
/// and file size. Bytes come from the provider's disk-verified per-file
/// tracking (`downloadedBytes` inside `task.torrentFiles`).
class _TorrentFileRow extends StatelessWidget {
  final Map<String, dynamic> file;
  final bool isDark;
  final Color accent;

  const _TorrentFileRow({
    required this.file,
    required this.isDark,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final selected = file['selected'] == true;
    final length = (file['length'] as num?)?.toInt() ?? 0;
    final downloaded = (file['downloadedBytes'] as num?)?.toInt() ?? 0;
    final p = length > 0 ? (downloaded / length).clamp(0.0, 1.0) : 0.0;
    final done = selected && p >= 1.0;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final name = (file['name'] as String? ?? '').replaceAll('+', ' ');

    return Padding(
      padding: const EdgeInsets.only(left: 12, bottom: 8),
      child: Row(
        children: [
          Icon(
            done
                ? Icons.check_circle_rounded
                : selected
                ? Icons.insert_drive_file_rounded
                : Icons.block_rounded,
            size: 13,
            color: done ? greenClr : (selected ? accent : mutedClr),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: AppTheme.dataStyle(
                    isDark: isDark,
                    size: 10.5,
                    weight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(1),
                  child: Stack(
                    children: [
                      Container(
                        height: 2,
                        decoration: AppTheme.progressTrack(
                          isDark: isDark,
                          radius: 1,
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: p,
                        child: Container(
                          height: 2,
                          decoration: BoxDecoration(
                            color: done ? greenClr : accent,
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Per-file percentage
          SizedBox(
            width: 36,
            child: Text(
              '${(p * 100).toStringAsFixed(0)}%',
              textAlign: TextAlign.end,
              style: AppTheme.dataStyle(
                isDark: isDark,
                size: 10,
                weight: FontWeight.w800,
                color: done ? greenClr : accent,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            child: Text(
              '${formatBytes(downloaded.toDouble())} / ${formatBytes(length.toDouble())}',
              textAlign: TextAlign.end,
              style: AppTheme.dataStyle(
                isDark: isDark,
                size: 9,
                weight: FontWeight.w500,
                color: mutedClr,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Playlist group card — groups playlist videos into one card
// ────────────────────────────────────────────────────────────────────────────

class PlaylistGroupCard extends StatefulWidget {
  final String playlistId;
  final String title;
  final List<DownloadTask> items;

  const PlaylistGroupCard({
    super.key,
    required this.playlistId,
    required this.title,
    required this.items,
  });

  @override
  State<PlaylistGroupCard> createState() => _PlaylistGroupCardState();
}

class _PlaylistGroupCardState extends State<PlaylistGroupCard>
    with HapticHelper {
  bool _expanded = false;

  int get _completedCount =>
      widget.items.where((t) => t.status == DownloadStatus.completed).length;

  double get _overallProgress {
    final total = widget.items.fold<int>(0, (s, t) => s + t.resolvedFileSize);
    if (total <= 0) return 0.0;
    final done = widget.items.fold<int>(0, (s, t) => s + t.downloadedBytes);
    return (done / total).clamp(0.0, 1.0);
  }

  bool get _anyDownloading =>
      widget.items.any((t) => t.status == DownloadStatus.downloading);

  bool get _allDone => _completedCount == widget.items.length;

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final provider = context.read<DownloadProvider>();
    final accent = _allDone
        ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
        : (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed);
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return _CardShell(
      accent: accent,
      isDark: isDark,
      onTap: () {
        triggerHaptic(settings);
        setState(() => _expanded = !_expanded);
      },
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.15),
                      width: 0.8,
                    ),
                  ),
                  child: Icon(
                    Icons.queue_music_rounded,
                    color: accent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: AppTheme.dataStyle(
                          isDark: isDark,
                          size: 14,
                          weight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: accent.withValues(alpha: 0.3),
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              isRtl
                                  ? 'قائمة تشغيل • ${widget.items.length} فيديو'
                                  : 'PLAYLIST • ${widget.items.length} VIDEOS',
                              style: AppTheme.microLabel(
                                isDark: isDark,
                                color: accent,
                                size: 8,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '$_completedCount/${widget.items.length}',
                            style: AppTheme.dataStyle(
                              isDark: isDark,
                              size: 11,
                              color: mutedClr,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (_anyDownloading)
                  _ControlButton(
                    icon: Icons.pause_rounded,
                    color: isDark
                        ? AppTheme.neonAmber
                        : AppTheme.lightNeonAmber,
                    tooltip: isRtl ? 'إيقاف الكل' : 'Pause all',
                    onPressed: () {
                      triggerHaptic(settings);
                      for (final t in widget.items) {
                        if (t.status == DownloadStatus.downloading) {
                          provider.pauseTask(t.id);
                        }
                      }
                    },
                  )
                else if (!_allDone)
                  _ControlButton(
                    icon: Icons.play_arrow_rounded,
                    color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                    filled: true,
                    tooltip: isRtl ? 'استئناف الكل' : 'Resume all',
                    onPressed: () {
                      triggerHaptic(settings);
                      for (final t in widget.items) {
                        if (t.status == DownloadStatus.paused ||
                            t.status == DownloadStatus.queued) {
                          provider.resumeTask(t.id);
                        }
                      }
                    },
                  ),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: AppTheme.motionBase,
                  child: Icon(
                    Icons.keyboard_arrow_up_rounded,
                    size: 20,
                    color: mutedClr,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Aggregate progress + total percentage
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Stack(
                      children: [
                        Container(
                          height: 6,
                          decoration: AppTheme.progressTrack(isDark: isDark),
                        ),
                        AnimatedFractionallySizedBox(
                          widthFactor: _overallProgress,
                          duration: const Duration(milliseconds: 400),
                          curve: AppTheme.motionCurve,
                          child: Container(
                            height: 6,
                            decoration: AppTheme.progressFill(accent),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${(_overallProgress * 100).toStringAsFixed(1)}%',
                  style: AppTheme.dataStyle(
                    isDark: isDark,
                    size: 15,
                    weight: FontWeight.w800,
                    color: accent,
                  ),
                ),
              ],
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  children: [
                    Divider(
                      color: isDark
                          ? AppTheme.borderSubtle
                          : AppTheme.lightBorderSubtle,
                      height: 1,
                    ),
                    const SizedBox(height: 10),
                    ...widget.items.map(
                      (t) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _MediaCard(task: t, compact: true),
                      ),
                    ),
                  ],
                ),
              ),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: AppTheme.motionBase,
              firstCurve: AppTheme.motionCurve,
              secondCurve: AppTheme.motionCurve,
              sizeCurve: AppTheme.motionCurve,
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Advanced Controls (Long Press)
// ────────────────────────────────────────────────────────────────────────────

void _showAdvancedControls(
  BuildContext context,
  DownloadTask task,
  SettingsProvider settings,
) {
  final isDark = settings.isDarkMode;
  final provider = context.read<DownloadProvider>();
  final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
  final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) {
      return Container(
        decoration: BoxDecoration(
          color: isDark ? AppTheme.surface : AppTheme.lightSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(
            color: AppTheme.accent(isDark).withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: secClr.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: Icon(
                  task.status == DownloadStatus.paused
                      ? Icons.play_arrow
                      : Icons.pause,
                  color: AppTheme.accent(isDark),
                ),
                title: Text(
                  task.status == DownloadStatus.paused ? 'Resume' : 'Pause',
                  style: TextStyle(color: textClr),
                ),
                onTap: () {
                  Navigator.pop(context);
                  if (task.status == DownloadStatus.paused) {
                    provider.resumeTask(task.id);
                  } else {
                    provider.pauseTask(task.id);
                  }
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.copy_rounded,
                  color: AppTheme.neonBlue,
                ),
                title: Text(
                  'Copy Download Link',
                  style: TextStyle(color: textClr),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  await Clipboard.setData(ClipboardData(text: task.url));
                  if (context.mounted) {
                    ThemedSnackbar.show(
                      context,
                      message: 'Link copied',
                      color: AppTheme.neonGreen,
                      icon: Icons.check,
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.link_rounded,
                  color: AppTheme.neonViolet,
                ),
                title: Text(
                  'Update Download Link',
                  style: TextStyle(color: textClr),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showUpdateLinkDialog(context, task, provider);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.folder_open_rounded,
                  color: AppTheme.neonGreen,
                ),
                title: Text('Open File', style: TextStyle(color: textClr)),
                onTap: () async {
                  Navigator.pop(context);
                  if (task.localFilePath.isNotEmpty) {
                    await openFile(context, task.localFilePath, settings);
                  }
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: AppTheme.neonRed,
                ),
                title: Text('Delete', style: TextStyle(color: textClr)),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDelete(context, task, provider);
                },
              ),
              if (task.isTorrent) ...[
                ListTile(
                  leading: const Icon(
                    Icons.info_outline_rounded,
                    color: AppTheme.neonAmber,
                  ),
                  title: Text('Properties', style: TextStyle(color: textClr)),
                  onTap: () {
                    Navigator.pop(context);
                    _showTorrentProperties(context, task, settings);
                  },
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      );
    },
  );
}

void _showUpdateLinkDialog(
  BuildContext context,
  DownloadTask task,
  DownloadProvider provider,
) {
  final urlController = TextEditingController(text: task.url);
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Update Link'),
      content: TextField(
        controller: urlController,
        decoration: const InputDecoration(hintText: 'Enter new URL'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () async {
            Navigator.pop(context);
            await provider.updateTaskUrlAndResume(
              task.id,
              urlController.text.trim(),
            );
          },
          child: const Text('Update'),
        ),
      ],
    ),
  );
}

// ────────────────────────────────────────────────────────────────────────────
// Torrent Properties Sheet
// ────────────────────────────────────────────────────────────────────────────

void _showTorrentProperties(
  BuildContext context,
  DownloadTask task,
  SettingsProvider settings,
) {
  final isDark = settings.isDarkMode;
  final provider = context.read<DownloadProvider>();
  final isRtl = L10n.isRtl(context);
  final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
  final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
  final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
  final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
  final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
  final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
  final amberClr = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;

  // Resolve live torrent stats.
  final torrentId = provider.providerTorrentIds[task.id];
  final TorrentUpdateInfo? stats = torrentId != null
      ? provider.providerLatestTorrentStats[torrentId]
      : null;

  final dlSpeed = task.speed;
  final ulSpeed = task.isTorrent
      ? provider.getTorrentUploadSpeed(task.id)
      : 0.0;
  final seeds = provider.getTorrentSeeds(task.id);
  final peers = provider.getTorrentPeers(task.id);

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) {
      return Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.surface : AppTheme.lightSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(
            color: AppTheme.accent(isDark).withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle bar
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: secClr.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Title
                Row(
                  children: [
                    Icon(Icons.info_outline_rounded, color: amberClr, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isRtl ? 'خصائص التورنت' : 'Torrent Properties',
                        style: TextStyle(
                          color: textClr,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // ── Basic Info ──────────────────────────────────────────────
                _sectionHeader(
                  isRtl ? 'المعلومات الأساسية' : 'BASIC INFO',
                  blueClr,
                  isDark,
                ),
                const SizedBox(height: 10),
                _propRow(
                  isRtl ? 'الاسم' : 'Name',
                  task.fileName,
                  textClr,
                  secClr,
                  isRtl,
                ),
                _propRow(
                  isRtl ? 'المسار' : 'Save Path',
                  task.savePath,
                  textClr,
                  secClr,
                  isRtl,
                  mono: true,
                ),
                _propRow(
                  isRtl ? 'الحجم الكلي' : 'Total Size',
                  formatBytes(task.resolvedFileSize),
                  textClr,
                  secClr,
                  isRtl,
                ),
                _propRow(
                  isRtl ? 'تم تحميل' : 'Downloaded',
                  formatBytes(task.downloadedBytes),
                  textClr,
                  secClr,
                  isRtl,
                ),
                _propRow(
                  isRtl ? 'الفئة' : 'Category',
                  task.category.isNotEmpty ? task.category : '—',
                  textClr,
                  secClr,
                  isRtl,
                ),
                const SizedBox(height: 20),
                // ── Transfer Info ───────────────────────────────────────────
                _sectionHeader(
                  isRtl ? 'معلومات النقل' : 'TRANSFER INFO',
                  greenClr,
                  isDark,
                ),
                const SizedBox(height: 10),
                _propRow(
                  isRtl ? 'سرعة التحميل' : 'Download Speed',
                  '${formatBytes(dlSpeed)}/s',
                  textClr,
                  secClr,
                  isRtl,
                ),
                _propRow(
                  isRtl ? 'سرعة الرفع' : 'Upload Speed',
                  '${formatBytes(ulSpeed)}/s',
                  textClr,
                  secClr,
                  isRtl,
                ),
                _propRow(
                  isRtl ? 'المزرعون' : 'Seeds',
                  stats != null ? '${stats.numSeeds}' : '$seeds',
                  textClr,
                  secClr,
                  isRtl,
                ),
                _propRow(
                  isRtl ? 'الأقران' : 'Peers',
                  stats != null ? '${stats.numPeers}' : '$peers',
                  textClr,
                  secClr,
                  isRtl,
                ),
                const SizedBox(height: 20),
                // ── Technical Info ──────────────────────────────────────────
                _sectionHeader(
                  isRtl ? 'المعلومات التقنية' : 'TECHNICAL INFO',
                  violetClr,
                  isDark,
                ),
                const SizedBox(height: 10),
                if (stats != null) ...[
                  _propRow(
                    isRtl ? 'القطع المكتملة' : 'Pieces',
                    '${stats.piecesHave} / ${stats.piecesTotal}',
                    textClr,
                    secClr,
                    isRtl,
                  ),
                  _propRow(
                    isRtl ? 'المُتتبع' : 'Current Tracker',
                    stats.currentTracker.isNotEmpty
                        ? stats.currentTracker
                        : '—',
                    textClr,
                    secClr,
                    isRtl,
                    mono: true,
                  ),
                  _propRow(
                    isRtl ? 'النسخ الموزعة' : 'Distributed Copies',
                    stats.distributedCopies.toStringAsFixed(2),
                    textClr,
                    secClr,
                    isRtl,
                  ),
                  _propRow(
                    isRtl ? 'الإعلان التالي' : 'Next Announce',
                    stats.nextAnnounceSeconds > 0
                        ? '${stats.nextAnnounceSeconds}s'
                        : '—',
                    textClr,
                    secClr,
                    isRtl,
                  ),
                ] else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      isRtl
                          ? 'لا توجد بيانات مباشرة (التورنت غير نشط)'
                          : 'No live data available (torrent is not active)',
                      style: TextStyle(color: mutedClr, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Widget _sectionHeader(String label, Color accentColor, bool isDark) {
  return Row(
    children: [
      Container(
        width: 3,
        height: 14,
        decoration: BoxDecoration(
          color: accentColor,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 8),
      Text(
        label,
        style: AppTheme.microLabel(
          isDark: isDark,
          size: 10,
        ).copyWith(color: accentColor, letterSpacing: 1.2),
      ),
    ],
  );
}

Widget _propRow(
  String label,
  String value,
  Color textClr,
  Color secClr,
  bool isRtl, {
  bool mono = false,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(label, style: TextStyle(color: secClr, fontSize: 12)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: textClr,
              fontSize: 12,
              fontFamily: mono ? 'monospace' : null,
            ),
            textAlign: isRtl ? TextAlign.right : TextAlign.left,
          ),
        ),
      ],
    ),
  );
}

void _confirmDelete(
  BuildContext context,
  DownloadTask task,
  DownloadProvider provider,
) async {
  final settings = context.read<SettingsProvider>();
  // Reuse the shared dialog (with the "also delete files from disk"
  // checkbox) instead of a bare Cancel/Delete confirm — otherwise deleting
  // from this menu silently never removed files on disk, unlike the card's
  // own delete button.
  final deleteFiles = await showDeleteConfirmationDialog(
    context,
    task,
    settings,
  );
  if (deleteFiles != null) {
    provider.deleteTask(task.id, deleteFiles: deleteFiles);
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Delete confirmation (shared)
// ────────────────────────────────────────────────────────────────────────────

Future<bool?> showDeleteConfirmationDialog(
  BuildContext context,
  DownloadTask task,
  SettingsProvider settings,
) {
  final isDark = settings.isDarkMode;
  final isRtl = L10n.isRtl(context);
  bool deleteFiles = false;
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (BuildContext context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return Directionality(
            textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
            child: AlertDialog(
              backgroundColor:
                  (isDark ? AppTheme.surface : AppTheme.lightSurface)
                      .withValues(alpha: 0.95),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: isDark
                      ? AppTheme.borderStrong
                      : AppTheme.lightBorderStrong,
                  width: 0.8,
                ),
              ),
              title: Text(
                L10n.of(context, 'delete_title'),
                style: TextStyle(
                  color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isRtl
                        ? 'هل أنت متأكد من حذف "${task.fileName}" من القائمة؟'
                        : 'Remove "${task.fileName}" from the list?',
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textSecondary
                          : AppTheme.lightTextSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: Checkbox(
                          value: deleteFiles,
                          activeColor: isDark
                              ? AppTheme.neonRed
                              : AppTheme.lightNeonRed,
                          onChanged: (val) =>
                              setState(() => deleteFiles = val ?? false),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: GestureDetector(
                          onTap: () =>
                              setState(() => deleteFiles = !deleteFiles),
                          child: Text(
                            L10n.of(context, 'delete_files_label'),
                            style: TextStyle(
                              color: isDark
                                  ? AppTheme.textPrimary
                                  : AppTheme.lightTextPrimary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  child: Text(
                    L10n.of(context, 'cancel_btn'),
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                TextButton(
                  child: Text(
                    L10n.of(context, 'delete_btn'),
                    style: TextStyle(
                      color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  onPressed: () => Navigator.of(
                    context,
                  ).pop({'confirmed': true, 'deleteFiles': deleteFiles}),
                ),
              ],
            ),
          );
        },
      );
    },
  ).then((result) {
    if (result != null && result['confirmed'] == true) {
      return result['deleteFiles'] as bool;
    }
    return null;
  });
}

class _TelemetryTile extends StatelessWidget {
  final IconData icon;
  final String label;

  const _TelemetryTile({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Expanded(
      child: Row(
        children: [
          Icon(icon, size: 14, color: isDark ? Colors.white54 : Colors.black54),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: isDark ? Colors.white54 : Colors.black54,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
