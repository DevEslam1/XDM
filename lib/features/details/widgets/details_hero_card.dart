import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/engine/torrent_file_normalizer.dart';
import '../../../core/utils/file_opener.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/responsive.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import 'details_sheets.dart';

/// Elevated hero card showing file identity, status badge, radial progress ring
/// (preserving [ValueKey('details_pulse_ring')] for pulse tests), tabular speed/ETA,
/// transferred bytes, and inline failure details when applicable.
class DetailsHeroCard extends StatelessWidget {
  final DownloadTask task;
  final Color statusColor;
  final String speedText;
  final String etaText;
  final AnimationController pulse;

  const DetailsHeroCard({
    super.key,
    required this.task,
    required this.statusColor,
    required this.speedText,
    required this.etaText,
    required this.pulse,
  });

  IconData _fileIconFor(DownloadTask task) {
    if (task.isTorrent) return Icons.hub_rounded;
    switch (task.category.toLowerCase()) {
      case 'video':
        return Icons.movie_rounded;
      case 'audio':
        return Icons.audiotrack_rounded;
      case 'document':
        return Icons.description_rounded;
      case 'archive':
        return Icons.folder_zip_rounded;
      case 'apk':
        return Icons.android_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;
    final isAmoled = settings.isAmoledMode;
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final mutedClr = AppTheme.textMutedOf(isDark);
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final ringDim = responsiveValue(context, 102).clamp(90.0, 112.0);

    return DmxCardShell(
      accent: statusColor,
      radius: DmxTokens.radiusXl,
      showRail: false,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // File header row
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: isDark ? 0.14 : 0.10),
                    borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
                    border: Border.all(
                      color:
                          statusColor.withValues(alpha: isDark ? 0.28 : 0.22),
                      width: DmxTokens.borderThin,
                    ),
                  ),
                  child: Icon(
                    _fileIconFor(task),
                    size: 20,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.fileName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          color: textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(
                                  alpha: isDark ? 0.14 : 0.10),
                              borderRadius:
                                  BorderRadius.circular(DmxTokens.radiusSm),
                              border: Border.all(
                                color: statusColor.withValues(
                                    alpha: isDark ? 0.30 : 0.25),
                                width: DmxTokens.borderThin,
                              ),
                            ),
                            child: Text(
                              L10n.translateStatusName(context, task.status)
                                  .toUpperCase(),
                              style: AppTheme.microLabel(
                                isDark: isDark,
                                color: statusColor,
                                size: 11,
                              ),
                            ),
                          ),
                          if (task.isTorrent &&
                              task.status == DownloadStatus.paused &&
                              task.resumeDataSaved)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: greenClr.withValues(
                                    alpha: isDark ? 0.14 : 0.10),
                                borderRadius:
                                    BorderRadius.circular(DmxTokens.radiusSm),
                                border: Border.all(
                                  color: greenClr.withValues(
                                      alpha: isDark ? 0.30 : 0.25),
                                  width: DmxTokens.borderThin,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.check_circle_outline_rounded,
                                    size: 12,
                                    color: greenClr,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Resume data saved',
                                    style: TextStyle(
                                      fontFamily: AppTheme.fontBody,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: greenClr,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Divider(
              height: 1,
              thickness: 0.8,
              color: AppTheme.hairlineBorder(isDark, isAmoled: isAmoled),
            ),
            const SizedBox(height: 16),
            // Telemetry ring + speed/ETA/size readouts
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                RepaintBoundary(
                  key: const ValueKey('details_pulse_ring'),
                  child: SizedBox(
                    width: ringDim,
                    height: ringDim,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedBuilder(
                          animation: pulse,
                          builder: (context, _) {
                            return CustomPaint(
                              size: Size(ringDim, ringDim),
                              painter: _RingPainter(
                                progress: task.progress,
                                color: statusColor,
                                glow: pulse.value,
                                isDark: isDark,
                              ),
                            );
                          },
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              task.progressPercentString,
                              style: AppTheme.dataStyle(
                                isDark: isDark,
                                size: 19,
                                weight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              task.isTorrent
                                  ? TorrentFileNormalizer
                                      .formatSummaryFromFiles(task.torrentFiles)
                                  : '${task.threadCount} CH',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTheme.microLabel(
                                isDark: isDark,
                                color: statusColor,
                                size: 11,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          speedText,
                          maxLines: 1,
                          style: AppTheme.dataStyle(
                            isDark: isDark,
                            size: 21,
                            weight: FontWeight.w800,
                            color: statusColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        etaText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.dataStyle(
                          isDark: isDark,
                          size: 12,
                          weight: FontWeight.w600,
                          color: mutedClr,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.panelBg(isDark, isAmoled: isAmoled),
                          borderRadius:
                              BorderRadius.circular(DmxTokens.radiusSm),
                          border: Border.all(
                            color: AppTheme.hairlineBorder(isDark,
                                isAmoled: isAmoled),
                            width: DmxTokens.borderThin,
                          ),
                        ),
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              task.downloadedSizeFormatted,
                              style: AppTheme.dataStyle(
                                isDark: isDark,
                                size: 12.5,
                                weight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              ' / ${task.sizeFormatted}',
                              style: AppTheme.dataStyle(
                                isDark: isDark,
                                size: 12,
                                weight: FontWeight.w500,
                                color: mutedClr,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (task.status == DownloadStatus.failed &&
                task.errorMessage != null &&
                task.errorMessage!.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: redClr.withValues(alpha: isDark ? 0.12 : 0.08),
                  borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                  border: Border.all(
                    color: redClr.withValues(alpha: isDark ? 0.30 : 0.24),
                    width: DmxTokens.borderThin,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline_rounded, color: redClr, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.errorMessage!,
                            style: TextStyle(
                              fontFamily: AppTheme.fontBody,
                              color: redClr,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (task.recoveryHint != null &&
                              task.recoveryHint!.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              task.recoveryHint!,
                              style: TextStyle(
                                fontFamily: AppTheme.fontBody,
                                color: AppTheme.textSecondaryOf(isDark),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double glow;
  final bool isDark;

  _RingPainter({
    required this.progress,
    required this.color,
    required this.glow,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width / 2 - 7).clamp(0.0, double.infinity);

    final track = Paint()
      ..color = isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7.5;
    canvas.drawCircle(center, radius, track);

    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    if (sweep > 0) {
      final halo = Paint()
        ..color = color.withValues(alpha: 0.10 + glow * 0.12)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 11.5
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        sweep,
        false,
        halo,
      );

      final fill = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7.5
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        sweep,
        false,
        fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      (old.progress - progress).abs() > 0.001 ||
      (old.glow - glow).abs() > 0.033 ||
      old.color != color ||
      old.isDark != isDark;
}

/// Primary and secondary action buttons below the hero card.
class DetailsActionRail extends StatelessWidget with HapticHelper {
  final DownloadTask task;
  final DownloadProvider provider;
  final SettingsProvider settings;
  final Color statusColor;

  const DetailsActionRail({
    super.key,
    required this.task,
    required this.provider,
    required this.settings,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final actions = <_ActionDef>[];
    final isPending = provider.isTaskOperationPending(task.id);

    if (isPending) {
      actions.add(
        _ActionDef(
          icon: task.status == DownloadStatus.downloading
              ? Icons.pause_rounded
              : Icons.play_arrow_rounded,
          label: isRtl ? 'جاري المعالجة...' : 'PROCESSING...',
          color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          filled: true,
          isLoading: true,
          onTap: () {},
        ),
      );
    } else if (task.status == DownloadStatus.downloading) {
      actions.add(
        _ActionDef(
          icon: Icons.pause_rounded,
          label: isRtl ? 'إيقاف' : 'PAUSE',
          color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
          filled: false,
          onTap: () {
            triggerHaptic(settings);
            provider.pauseTask(task.id);
          },
        ),
      );
    } else if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.queued) {
      actions.add(
        _ActionDef(
          icon: Icons.play_arrow_rounded,
          label: task.status == DownloadStatus.queued
              ? (isRtl ? 'بدء' : 'START')
              : (isRtl ? 'استئناف' : 'RESUME'),
          color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          filled: true,
          onTap: () {
            triggerHaptic(settings);
            provider.resumeTask(task.id);
          },
        ),
      );
    } else if (task.status == DownloadStatus.failed) {
      actions.add(
        _ActionDef(
          icon: Icons.refresh_rounded,
          label: isRtl ? 'إعادة' : 'RETRY',
          color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
          filled: true,
          onTap: () {
            triggerHaptic(settings);
            provider.retryTask(task.id);
          },
        ),
      );
    } else if (task.status == DownloadStatus.completed) {
      actions.add(
        _ActionDef(
          icon: Icons.folder_open_rounded,
          label: isRtl ? 'فتح الملف' : 'OPEN FILE',
          color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          filled: true,
          onTap: () {
            triggerHaptic(settings);
            openFile(context, task.localFilePath, settings);
          },
        ),
      );
    }

    actions.add(
      _ActionDef(
        icon: Icons.delete_outline_rounded,
        label: L10n.of(context, 'delete_btn'),
        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
        filled: false,
        onTap: () async {
          triggerHaptic(settings);
          final deleteFiles = await showDetailsDeleteTaskDialog(
            context,
            task,
            settings,
          );
          if (!context.mounted) return;
          if (deleteFiles != null) {
            Navigator.pop(context);
            final ok =
                await provider.deleteTask(task.id, deleteFiles: deleteFiles);
            if (context.mounted) {
              ThemedSnackbar.show(
                context,
                message: ok
                    ? (isRtl
                        ? 'تم حذف التنزيل بنجاح'
                        : 'Download deleted successfully')
                    : (isRtl ? 'فشل حذف التنزيل' : 'Failed to delete download'),
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                icon: ok ? Icons.delete : Icons.error_outline,
                isDarkMode: isDark,
              );
            }
          }
        },
      ),
    );

    return Row(
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(child: _DetailsActionButton(def: actions[i])),
        ],
      ],
    );
  }
}

class _ActionDef {
  final IconData icon;
  final String label;
  final Color color;
  final bool filled;
  final bool isLoading;
  final VoidCallback onTap;

  const _ActionDef({
    required this.icon,
    required this.label,
    required this.color,
    required this.filled,
    this.isLoading = false,
    required this.onTap,
  });
}

class _DetailsActionButton extends StatelessWidget {
  final _ActionDef def;

  const _DetailsActionButton({required this.def});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = def.filled ? AppTheme.inkOn(def.color) : def.color;
    final bg = def.filled
        ? def.color
        : def.color.withValues(alpha: isDark ? 0.12 : 0.08);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: def.isLoading ? null : def.onTap,
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        child: AnimatedContainer(
          duration: AppTheme.motionFast,
          constraints: const BoxConstraints(minHeight: 50),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
            border: Border.all(
              color: def.filled
                  ? def.color
                  : def.color.withValues(alpha: isDark ? 0.30 : 0.25),
              width: DmxTokens.borderThin,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (def.isLoading)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(fg),
                  ),
                )
              else
                Icon(def.icon, size: 19, color: fg),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  def.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
