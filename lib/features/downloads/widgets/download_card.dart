import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
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
///   • Torrent / magnet  -> _TorrentCard   (seeds/peers, upload, files, seeding)
///   • Media / playlist  -> _MediaCard     (quality badge, audio track, merge)
///   • Single file       -> _FileCard      (chunked multi-thread progress)
///
/// Playlist videos (task.playlistId set) are grouped by the home screen into
/// a [PlaylistGroupCard]; individual items still render as _MediaCard when
/// expanded.
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

// ═══════════════════════════════════════════════════════════════
// Shared helpers
// ═══════════════════════════════════════════════════════════════
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

String _statusLabel(BuildContext context, DownloadStatus status) {
  return L10n.translateStatusName(context, status);
}

// ═══════════════════════════════════════════════════════════════
// Shared sub-widgets
// ═══════════════════════════════════════════════════════════════

/// Card shell with a signature cockpit notch + status accent rail.
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
        borderRadius: BorderRadius.circular(18),
        child: Container(
          decoration: AppTheme.panel(
            isDark: isDark,
            radius: 18,
            accentColor: accent,
            accentAlpha: 0.18,
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
                      topLeft: Radius.circular(18),
                      bottomLeft: Radius.circular(18),
                    ),
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

/// Status chip that pulses while downloading/seeding.
class _StatusChip extends StatefulWidget {
  final DownloadTask task;
  final bool isDark;
  final String? overrideLabel;
  const _StatusChip({
    required this.task,
    required this.isDark,
    this.overrideLabel,
  });

  @override
  State<_StatusChip> createState() => _StatusChipState();
}

class _StatusChipState extends State<_StatusChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );

  bool get _isActive =>
      widget.task.status == DownloadStatus.downloading ||
      (widget.task.status == DownloadStatus.completed &&
          widget.task.isTorrent &&
          widget.task.seedingEnabled);

  @override
  void initState() {
    super.initState();
    if (_isActive) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _StatusChip old) {
    super.didUpdateWidget(old);
    if (_isActive && !_pulse.isAnimating) _pulse.repeat(reverse: true);
    if (!_isActive && _pulse.isAnimating) _pulse.stop();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(widget.task.status, widget.isDark);
    final label =
        widget.overrideLabel ?? _statusLabel(context, widget.task.status);
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: color.withValues(
                alpha: _isActive ? 0.35 + _pulse.value * 0.3 : 0.3,
              ),
              width: 0.8,
            ),
          ),
          child: Text(
            label.toUpperCase(),
            style: AppTheme.microLabel(
              isDark: widget.isDark,
              color: color,
              size: 8.5,
            ),
          ),
        );
      },
    );
  }
}

/// Multi-thread chunked progress bar — one segment per thread.
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
    if (chunks.length <= 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(
          children: [
            Container(
              height: 6,
              decoration: AppTheme.progressTrack(isDark: isDark),
            ),
            FractionallySizedBox(
              widthFactor: task.progress.clamp(0.0, 1.0),
              child: Container(
                height: 6,
                decoration: AppTheme.progressFill(color),
              ),
            ),
          ],
        ),
      );
    }
    return Row(
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
                  height: 6,
                  decoration: AppTheme.progressTrack(isDark: isDark, radius: 3),
                ),
                FractionallySizedBox(
                  widthFactor: p,
                  child: Container(
                    height: 6,
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
}

/// Icon control button with press-scale micro-interaction.
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
            padding: const EdgeInsets.all(8),
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
              size: 17,
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

/// Standard control cluster shared by all variants.
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
                  message: isRtl ? 'تم حذف التنزيل بنجاح' : 'Download deleted',
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

/// Data readout (speed / size / eta) in the display face.
class _DataReadout extends StatelessWidget {
  final String value;
  final Color color;
  final bool isDark;
  final double size;
  const _DataReadout({
    required this.value,
    required this.color,
    required this.isDark,
    this.size = 12,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      style: AppTheme.dataStyle(isDark: isDark, color: color, size: size),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Variant 1 — Single file
// ═══════════════════════════════════════════════════════════════
class _FileCard extends StatelessWidget with HapticHelper {
  final DownloadTask task;
  final bool compact;
  const _FileCard({required this.task, required this.compact});

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final statusColor = _statusColor(task.status, isDark);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
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
        padding: const EdgeInsets.all(14),
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
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          _StatusChip(task: task, isDark: isDark),
                          const SizedBox(width: 8),
                          Text(
                            L10n.translateCategory(
                              context,
                              task.category,
                            ).toUpperCase(),
                            style: AppTheme.microLabel(
                              isDark: isDark,
                              size: 8.5,
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
            const SizedBox(height: 14),
            _ChunkedProgressBar(task: task, isDark: isDark, color: statusColor),
            const SizedBox(height: 10),
            Row(
              children: [
                _DataReadout(
                  value:
                      '${task.downloadedSizeFormatted} / ${task.sizeFormatted}',
                  color: mutedClr,
                  isDark: isDark,
                  size: 11,
                ),
                const Spacer(),
                if (task.status == DownloadStatus.downloading) ...[
                  Icon(
                    Icons.arrow_downward_rounded,
                    size: 12,
                    color: statusColor,
                  ),
                  const SizedBox(width: 3),
                  _DataReadout(
                    value: task.speedFormatted,
                    color: statusColor,
                    isDark: isDark,
                    size: 11,
                  ),
                  const SizedBox(width: 10),
                ],
                _DataReadout(
                  value: task.progressPercentString,
                  color: textClr,
                  isDark: isDark,
                  size: 12,
                ),
              ],
            ),
            if (task.status == DownloadStatus.downloading &&
                task.etaFormatted.isNotEmpty) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  L10n.translateStatus(context, task.status, task.etaFormatted),
                  style: AppTheme.microLabel(isDark: isDark, size: 9),
                ),
              ),
            ],
            if (task.status == DownloadStatus.failed &&
                task.errorMessage != null) ...[
              const SizedBox(height: 6),
              Text(
                task.errorMessage!,
                style: AppTheme.microLabel(
                  isDark: isDark,
                  color: statusColor,
                  size: 9,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Variant 2 — Media (single video / audio / playlist item)
// ═══════════════════════════════════════════════════════════════
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
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
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
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // media thumbnail placeholder
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
                          // quality badge
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
            const SizedBox(height: 14),
            _ChunkedProgressBar(task: task, isDark: isDark, color: statusColor),
            // separate audio-track progress when merging
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
            const SizedBox(height: 10),
            Row(
              children: [
                _DataReadout(
                  value:
                      '${task.downloadedSizeFormatted} / ${task.sizeFormatted}',
                  color: mutedClr,
                  isDark: isDark,
                  size: 11,
                ),
                const Spacer(),
                if (task.status == DownloadStatus.downloading) ...[
                  Icon(
                    Icons.arrow_downward_rounded,
                    size: 12,
                    color: statusColor,
                  ),
                  const SizedBox(width: 3),
                  _DataReadout(
                    value: task.speedFormatted,
                    color: statusColor,
                    isDark: isDark,
                    size: 11,
                  ),
                  const SizedBox(width: 10),
                ],
                _DataReadout(
                  value: task.progressPercentString,
                  color: textClr,
                  isDark: isDark,
                  size: 12,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Variant 3 — Torrent / magnet
// ═══════════════════════════════════════════════════════════════
class _TorrentCard extends StatefulWidget {
  final DownloadTask task;
  final bool compact;
  const _TorrentCard({required this.task, required this.compact});

  @override
  State<_TorrentCard> createState() => _TorrentCardState();
}

class _TorrentCardState extends State<_TorrentCard> with HapticHelper {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final statusColor = _statusColor(widget.task.status, isDark);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final isMagnet = widget.task.url.startsWith('magnet:');
    final isSeeding =
        widget.task.status == DownloadStatus.completed &&
        widget.task.seedingEnabled;

    return Selector<DownloadProvider, ({int seeds, int peers, double uploadSpeed})>(
      selector: (context, provider) => (
        seeds: provider.getTorrentSeeds(widget.task.id),
        peers: provider.getTorrentPeers(widget.task.id),
        uploadSpeed: provider.getTorrentUploadSpeed(widget.task.id),
      ),
      builder: (context, stats, _) {
        final seeds = stats.seeds;
        final peers = stats.peers;
        final uploadSpeed = stats.uploadSpeed;
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
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                                overrideLabel: isSeeding
                                    ? (isRtl ? 'مشاركة' : 'SEEDING')
                                    : null,
                              ),
                              _PeerChip(
                                icon: Icons.arrow_upward_rounded,
                                label: '$seeds',
                                color: greenClr,
                                isDark: isDark,
                              ),
                              _PeerChip(
                                icon: Icons.arrow_downward_rounded,
                                label: '$peers',
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
                    Column(
                      children: [
                        _ControlCluster(task: widget.task),
                        if (fileCount > 0) ...[
                          const SizedBox(height: 6),
                          GestureDetector(
                            onTap: () {
                              triggerHaptic(settings);
                              setState(() => _expanded = !_expanded);
                            },
                            child: AnimatedRotation(
                              turns: _expanded ? 0.5 : 0,
                              duration: AppTheme.motionBase,
                              child: Icon(
                                Icons.keyboard_arrow_up_rounded,
                                size: 18,
                                color: mutedClr,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _ChunkedProgressBar(
                  task: widget.task,
                  isDark: isDark,
                  color: statusColor,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _DataReadout(
                      value:
                          '${widget.task.downloadedSizeFormatted} / ${widget.task.sizeFormatted}',
                      color: mutedClr,
                      isDark: isDark,
                      size: 11,
                    ),
                    const Spacer(),
                    if (widget.task.status == DownloadStatus.downloading) ...[
                      Icon(
                        Icons.arrow_downward_rounded,
                        size: 12,
                        color: statusColor,
                      ),
                      const SizedBox(width: 3),
                      _DataReadout(
                        value: widget.task.speedFormatted,
                        color: statusColor,
                        isDark: isDark,
                        size: 11,
                      ),
                      const SizedBox(width: 10),
                    ],
                    if (isSeeding || uploadSpeed > 0) ...[
                      Icon(
                        Icons.arrow_upward_rounded,
                        size: 12,
                        color: violetClr,
                      ),
                      const SizedBox(width: 3),
                      _DataReadout(
                        value: '${formatBytes(uploadSpeed)}/s',
                        color: violetClr,
                        isDark: isDark,
                        size: 11,
                      ),
                      const SizedBox(width: 10),
                    ],
                    _DataReadout(
                      value: widget.task.progressPercentString,
                      color: textClr,
                      isDark: isDark,
                      size: 12,
                    ),
                  ],
                ),
                // seeding toggle when completed
                if (widget.task.status == DownloadStatus.completed) ...[
                  const SizedBox(height: 10),
                  Divider(
                    color: isDark
                        ? AppTheme.borderSubtle
                        : AppTheme.lightBorderSubtle,
                    height: 1,
                  ),
                  const SizedBox(height: 8),
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
                // expandable file list
                AnimatedCrossFade(
                  firstChild: const SizedBox(width: double.infinity),
                  secondChild: _TorrentFileList(
                    task: widget.task,
                    isDark: isDark,
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
      },
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

class _TorrentFileList extends StatelessWidget {
  final DownloadTask task;
  final bool isDark;
  const _TorrentFileList({required this.task, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final files = task.torrentFiles ?? [];
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        children: files.map((f) {
          final selected = f['selected'] == true;
          final length = (f['length'] as num?)?.toInt() ?? 0;
          final downloaded = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
          final p = length > 0 ? (downloaded / length).clamp(0.0, 1.0) : 0.0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.insert_drive_file_rounded
                      : Icons.block_rounded,
                  size: 13,
                  color: selected
                      ? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue)
                      : mutedClr,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    (f['name'] as String? ?? '').replaceAll('+', ' '),
                    style: AppTheme.dataStyle(
                      isDark: isDark,
                      size: 10.5,
                      weight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 70,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: Stack(
                      children: [
                        Container(
                          height: 3,
                          decoration: AppTheme.progressTrack(
                            isDark: isDark,
                            radius: 2,
                          ),
                        ),
                        FractionallySizedBox(
                          widthFactor: p,
                          child: Container(
                            height: 3,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? AppTheme.neonBlue
                                  : AppTheme.lightNeonBlue,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 52,
                  child: Text(
                    formatBytes(length.toDouble()),
                    textAlign: TextAlign.end,
                    style: AppTheme.dataStyle(
                      isDark: isDark,
                      size: 9,
                      color: mutedClr,
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Playlist group card — groups playlist videos into one card
// ═══════════════════════════════════════════════════════════════
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
    final total = widget.items.fold<int>(0, (s, t) => s + t.fileSize);
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
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
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
                // bulk controls
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
            // aggregate progress
            ClipRRect(
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
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${(_overallProgress * 100).toStringAsFixed(0)}%',
                  style: AppTheme.dataStyle(
                    isDark: isDark,
                    size: 12,
                    color: textClr,
                  ),
                ),
                const Spacer(),
                if (_anyDownloading)
                  Icon(Icons.downloading_rounded, size: 13, color: accent),
              ],
            ),
            // expanded item list
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
                      (t) => _MediaCard(task: t, compact: true),
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

// ═══════════════════════════════════════════════════════════════
// Advanced Controls (Long Press)
// ═══════════════════════════════════════════════════════════════
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

void _confirmDelete(
  BuildContext context,
  DownloadTask task,
  DownloadProvider provider,
) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete Download?'),
      content: const Text('Are you sure you want to remove this download?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.neonRed),
          onPressed: () {
            Navigator.pop(context);
            provider.deleteTask(task.id);
          },
          child: const Text('Delete', style: TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
}

// ═══════════════════════════════════════════════════════════════
// Delete confirmation (shared)
// ═══════════════════════════════════════════════════════════════
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
