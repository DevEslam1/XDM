import 'package:material_ui/material_ui.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/torrent_service.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../downloads/models/download_task.dart';

class TorrentStatsDashboard extends StatelessWidget {
  final DownloadTask task;
  final TorrentUpdateInfo? stats;
  final bool isDark;

  const TorrentStatsDashboard({
    super.key,
    required this.task,
    required this.stats,
    required this.isDark,
  });

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  String _formatSpeed(num bps) {
    if (!bps.isFinite || bps <= 0) return '0 B/s';
    final kb = bps / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB/s';
    return '${(kb / 1024).toStringAsFixed(1)} MB/s';
  }

  String _formatDuration(Duration duration) {
    if (duration.inSeconds <= 0) return '0s';
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) return '${hours}h ${minutes}m';
    if (minutes > 0) return '${minutes}m ${seconds}s';
    return '${seconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final totalDownloaded = stats?.totalPayloadDownload ?? task.downloadedBytes;
    final totalUploaded =
        (stats?.totalPayloadUpload != null && stats!.totalPayloadUpload > 0)
            ? stats!.totalPayloadUpload
            : task.uploadedBytes;
    final totalSize = task.resolvedFileSize;
    final ratio = totalDownloaded > 0
        ? totalUploaded / totalDownloaded
        : (totalSize > 0 ? totalUploaded / totalSize : 0.0);
    final seedingDuration = task.completedAt != null
        ? DateTime.now().difference(task.completedAt!)
        : Duration.zero;

    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final amberClr = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textSecondary = AppTheme.textSecondaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);

    final showLiveRates =
        stats != null && (stats!.downloadRate > 0 || stats!.uploadRate > 0);
    final showPieces = stats != null && stats!.piecesTotal > 0;
    final piecesRatio = showPieces
        ? (stats!.piecesHave / stats!.piecesTotal).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      padding: const EdgeInsets.all(DmxTokens.spaceLg),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor(isDark),
        borderRadius: BorderRadius.circular(DmxTokens.radiusLg),
        border: Border.all(
          color: AppTheme.hairlineBorder(isDark),
          width: DmxTokens.borderThin,
        ),
        boxShadow: AppTheme.cardShadow(isDark),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header with optional live DL/UL speed pills
          Row(
            children: [
              Container(
                width: 3,
                height: 12,
                decoration: BoxDecoration(
                  color: blueClr,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'LIFETIME STATISTICS',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    fontSize: DmxTokens.textXs,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: textSecondary,
                  ),
                ),
              ),
              if (showLiveRates) ...[
                const SizedBox(width: 8),
                _SpeedBadge(
                  icon: Icons.arrow_downward_rounded,
                  value: _formatSpeed(stats!.downloadRate),
                  color: blueClr,
                  isDark: isDark,
                ),
                const SizedBox(width: 6),
                _SpeedBadge(
                  icon: Icons.arrow_upward_rounded,
                  value: _formatSpeed(stats!.uploadRate),
                  color: greenClr,
                  isDark: isDark,
                ),
              ],
            ],
          ),
          const SizedBox(height: DmxTokens.spaceMd),

          // Responsive metric tiles (4 across on wide, 2x2 on narrow 320-420px)
          LayoutBuilder(
            builder: (context, constraints) {
              final dlTile = _StatTile(
                label: 'Downloaded',
                value: _formatBytes(totalDownloaded),
                accent: blueClr,
                icon: Icons.download_rounded,
                isDark: isDark,
              );
              final ulTile = _StatTile(
                label: 'Uploaded',
                value: _formatBytes(totalUploaded),
                accent: greenClr,
                icon: Icons.upload_rounded,
                isDark: isDark,
              );
              final ratioTile = _StatTile(
                label: 'Ratio',
                value: ratio.toStringAsFixed(2),
                accent: violetClr,
                icon: Icons.balance_rounded,
                isDark: isDark,
              );
              final seedingTile = _StatTile(
                label: 'Seeding',
                value: _formatDuration(seedingDuration),
                accent: amberClr,
                icon: Icons.schedule_rounded,
                isDark: isDark,
              );

              if (constraints.maxWidth >= 420) {
                return Row(
                  children: [
                    Expanded(child: dlTile),
                    const SizedBox(width: DmxTokens.spaceSm),
                    Expanded(child: ulTile),
                    const SizedBox(width: DmxTokens.spaceSm),
                    Expanded(child: ratioTile),
                    const SizedBox(width: DmxTokens.spaceSm),
                    Expanded(child: seedingTile),
                  ],
                );
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(child: dlTile),
                      const SizedBox(width: DmxTokens.spaceSm),
                      Expanded(child: ulTile),
                    ],
                  ),
                  const SizedBox(height: DmxTokens.spaceSm),
                  Row(
                    children: [
                      Expanded(child: ratioTile),
                      const SizedBox(width: DmxTokens.spaceSm),
                      Expanded(child: seedingTile),
                    ],
                  ),
                ],
              );
            },
          ),

          // Truthful Pieces row (only when piece data is known; exact vs estimated)
          if (showPieces) ...[
            const SizedBox(height: DmxTokens.spaceSm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.surfaceColor(isDark, elevated: true),
                borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                border: Border.all(
                  color: AppTheme.hairlineBorder(isDark),
                  width: DmxTokens.borderThin,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(Icons.grid_view_rounded, size: 14, color: violetClr),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          TorrentService.fileProgressSupported
                              ? 'Pieces'
                              : 'Pieces (est.)',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: AppTheme.fontDisplay,
                            fontSize: DmxTokens.textXs,
                            fontWeight: FontWeight.w600,
                            color: textMuted,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        TorrentService.fileProgressSupported
                            ? '${stats!.piecesHave}/${stats!.piecesTotal}'
                            : '~${stats!.piecesHave}/${stats!.piecesTotal}',
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          fontSize: DmxTokens.textMd,
                          fontWeight: FontWeight.w700,
                          color: textPrimary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
                    child: LinearProgressIndicator(
                      value: piecesRatio,
                      minHeight: 5,
                      backgroundColor: (isDark ? Colors.white : Colors.black)
                          .withValues(alpha: isDark ? 0.08 : 0.07),
                      valueColor: AlwaysStoppedAnimation<Color>(violetClr),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SpeedBadge extends StatelessWidget {
  final IconData icon;
  final String value;
  final Color color;
  final bool isDark;

  const _SpeedBadge({
    required this.icon,
    required this.value,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
        border: Border.all(
          color: color.withValues(alpha: isDark ? 0.28 : 0.22),
          width: 0.7,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(
            value,
            style: TextStyle(
              fontFamily: AppTheme.fontDisplay,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;
  final IconData icon;
  final bool isDark;

  const _StatTile({
    required this.label,
    required this.value,
    required this.accent,
    required this.icon,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);

    return Semantics(
      container: true,
      label: '$label: $value',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.surfaceColor(isDark, elevated: true),
          borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
          border: Border.all(
            color: AppTheme.hairlineBorder(isDark),
            width: DmxTokens.borderThin,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(icon, size: 12, color: accent),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      fontSize: DmxTokens.textXs,
                      fontWeight: FontWeight.w600,
                      color: textMuted,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  fontFamily: AppTheme.fontDisplay,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                  color: textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
