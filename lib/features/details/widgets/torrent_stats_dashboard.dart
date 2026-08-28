import 'package:flutter/material.dart';
import '../../../core/app_theme.dart';
import '../../../core/domain/torrent_models.dart';
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

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:
            (isDark ? AppTheme.surface : Colors.white).withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue)
              .withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'LIFETIME STATISTICS',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Expanded(
                  child:
                      _buildStat('Downloaded', _formatBytes(totalDownloaded))),
              Expanded(
                  child: _buildStat('Uploaded', _formatBytes(totalUploaded))),
              Expanded(child: _buildStat('Ratio', ratio.toStringAsFixed(2))),
              Expanded(
                  child:
                      _buildStat('Seeding', _formatDuration(seedingDuration))),
            ],
          ),
          if (stats != null && stats!.piecesTotal > 0) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                // Piece counts are estimated from total size / 256 KB on the
                // 1.9.2 bridge (no real bitfield export), so they are labelled
                // estimated rather than presented as an exact piece map.
                // "Availability" (distributedCopies) is hardcoded 0.0 by the
                // bridge, so it is omitted instead of shown as a fake 0.00x.
                Expanded(
                  child: _buildStat(
                    'Pieces (est.)',
                    '~${stats!.piecesHave}/${stats!.piecesTotal}',
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStat(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
          ),
        ),
      ],
    );
  }
}
