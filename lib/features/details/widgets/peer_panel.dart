import 'package:material_ui/material_ui.dart';

import '../../../core/app_theme.dart';
import '../../../core/domain/torrent_models.dart';
import '../../../shared/design/dmx_tokens.dart';

class PeerInfo {
  final String ip;
  final int port;
  final String client;
  final String country;
  final double progress;
  final int downloadSpeed;
  final int uploadSpeed;
  final bool isSeed;
  final bool isEncrypted;
  final bool isOutgoing;
  final String flags;
  final double relevance;

  const PeerInfo({
    required this.ip,
    required this.port,
    required this.client,
    required this.country,
    required this.progress,
    required this.downloadSpeed,
    required this.uploadSpeed,
    required this.isSeed,
    required this.isEncrypted,
    this.isOutgoing = false,
    required this.flags,
    this.relevance = 1.0,
  });
}

class PeerPanel extends StatelessWidget {
  final int torrentId;
  final bool isDark;
  final List<PeerInfo> peers;

  /// Aggregate swarm counts from the native status stream.
  ///
  /// The libtorrent bridge exposes no per-peer enumeration (`lt_get_peer_info`
  /// is not an export), so [peers] is normally empty and this snapshot is the
  /// only real swarm data available. When [peers] does arrive it takes over and
  /// the aggregate view is skipped.
  final TorrentSwarmSnapshot? swarm;

  const PeerPanel({
    super.key,
    required this.torrentId,
    required this.isDark,
    this.peers = const [],
    this.swarm,
  });

  String _formatSpeed(int bps) {
    if (bps <= 0) return '0 B/s';
    final kb = bps / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB/s';
    return '${(kb / 1024).toStringAsFixed(1)} MB/s';
  }

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final s = swarm;

    // Prefer the real connection list when one exists; otherwise fall back to
    // the aggregate counts so the panel reports the swarm instead of claiming
    // there are no connections at all.
    final seeds = peers.isNotEmpty
        ? peers.where((p) => p.isSeed).length
        : (s?.connectedSeeds ?? 0);
    final leeches = peers.isNotEmpty
        ? peers.where((p) => !p.isSeed).length
        : (s?.connectedPeers ?? 0);
    final connectionCount = peers.isNotEmpty ? peers.length : seeds + leeches;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header row with connected count badge + seeds/leeches pills
        Wrap(
          spacing: 8,
          runSpacing: 6,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Peers',
                  style: TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: textPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: blueClr.withValues(alpha: isDark ? 0.16 : 0.11),
                    borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
                  ),
                  child: Text(
                    '$connectionCount',
                    style: TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      fontSize: DmxTokens.textXs,
                      fontWeight: FontWeight.w700,
                      color: blueClr,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _CountChip(
                  label: 'Seeds',
                  value: '$seeds',
                  color: greenClr,
                  isDark: isDark,
                ),
                const SizedBox(width: 6),
                _CountChip(
                  label: 'Leeches',
                  value: '$leeches',
                  color: blueClr,
                  isDark: isDark,
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: DmxTokens.spaceMd),

        if (peers.isEmpty)
          _SwarmSummary(swarm: s, isDark: isDark)
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: peers.length,
            separatorBuilder: (_, __) =>
                const SizedBox(height: DmxTokens.spaceSm),
            itemBuilder: (context, index) => _PeerCard(
              peer: peers[index],
              isDark: isDark,
              formatSpeed: _formatSpeed,
            ),
          ),
      ],
    );
  }
}

class _CountChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final bool isDark;

  const _CountChip({
    required this.label,
    required this.value,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
        border: Border.all(
          color: color.withValues(alpha: isDark ? 0.25 : 0.20),
          width: 0.7,
        ),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontFamily: AppTheme.fontDisplay,
          fontSize: DmxTokens.textXs,
          fontWeight: FontWeight.w600,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _PeerCard extends StatelessWidget {
  final PeerInfo peer;
  final bool isDark;
  final String Function(int bps) formatSpeed;

  const _PeerCard({
    required this.peer,
    required this.isDark,
    required this.formatSpeed,
  });

  @override
  Widget build(BuildContext context) {
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final accent = peer.isSeed ? greenClr : blueClr;
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);
    final clampedProgress = peer.progress.clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(DmxTokens.spaceMd),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor(isDark),
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
              // Encryption & direction badge
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: isDark ? 0.14 : 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      peer.isEncrypted
                          ? Icons.lock_outline_rounded
                          : Icons.link_rounded,
                      size: 14,
                      color: accent,
                    ),
                    Icon(
                      peer.isOutgoing
                          ? Icons.north_east_rounded
                          : Icons.south_west_rounded,
                      size: 10,
                      color: textMuted,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            peer.country.isEmpty
                                ? '${peer.ip}:${peer.port}'
                                : '${peer.ip}:${peer.port} (${peer.country})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: AppTheme.fontDisplay,
                              fontSize: DmxTokens.textMd,
                              fontWeight: FontWeight.w700,
                              color: textPrimary,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        if (peer.flags.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: (isDark ? Colors.white : Colors.black)
                                  .withValues(alpha: isDark ? 0.08 : 0.06),
                              borderRadius:
                                  BorderRadius.circular(DmxTokens.radiusSm),
                            ),
                            child: Text(
                              peer.flags,
                              style: TextStyle(
                                fontFamily: AppTheme.fontDisplay,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textSecondaryOf(isDark),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${peer.client.isNotEmpty ? peer.client : 'Peer'} • Quality ${(peer.relevance * 100).toStringAsFixed(0)}%',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppTheme.fontBody,
                        fontSize: DmxTokens.textXs,
                        color: textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
                  child: LinearProgressIndicator(
                    value: clampedProgress,
                    minHeight: 4,
                    backgroundColor: (isDark ? Colors.white : Colors.black)
                        .withValues(alpha: isDark ? 0.08 : 0.07),
                    valueColor: AlwaysStoppedAnimation<Color>(accent),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(clampedProgress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontFamily: AppTheme.fontDisplay,
                  fontSize: DmxTokens.textXs,
                  fontWeight: FontWeight.w700,
                  color: accent,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '↓ ${formatSpeed(peer.downloadSpeed)}',
                style: TextStyle(
                  fontFamily: AppTheme.fontDisplay,
                  fontSize: DmxTokens.textXs,
                  fontWeight: FontWeight.w600,
                  color: blueClr,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '↑ ${formatSpeed(peer.uploadSpeed)}',
                style: TextStyle(
                  fontFamily: AppTheme.fontDisplay,
                  fontSize: DmxTokens.textXs,
                  fontWeight: FontWeight.w600,
                  color: greenClr,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Aggregate swarm view shown when no per-peer list is available.
class _SwarmSummary extends StatelessWidget {
  final TorrentSwarmSnapshot? swarm;
  final bool isDark;

  const _SwarmSummary({required this.swarm, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final textSecondary = AppTheme.textSecondaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final orangeClr = isDark ? AppTheme.neonOrange : AppTheme.lightNeonOrange;
    final s = swarm;

    if (s == null || s.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        decoration: BoxDecoration(
          color: AppTheme.surfaceColor(isDark),
          borderRadius: BorderRadius.circular(DmxTokens.radiusLg),
          border: Border.all(
            color: AppTheme.hairlineBorder(isDark),
            width: DmxTokens.borderThin,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined, size: 24, color: textMuted),
            const SizedBox(height: 8),
            Text(
              'No peer connections currently active.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: AppTheme.fontBody,
                fontSize: DmxTokens.textSm,
                color: textMuted,
              ),
            ),
          ],
        ),
      );
    }

    final rows = <Widget>[
      _row(
        'Connected seeds',
        '${s.connectedSeeds}',
        greenClr,
        Icons.cloud_download_outlined,
        textSecondary,
      ),
      _row(
        'Connected peers',
        '${s.connectedPeers}',
        blueClr,
        Icons.people_outline_rounded,
        textSecondary,
      ),
    ];

    if (s.hasSwarmScrape) {
      rows.add(_row(
        'Swarm (tracker)',
        '${s.swarmSeeds ?? '—'} seeds · ${s.swarmPeers ?? '—'} peers',
        violetClr,
        Icons.public_outlined,
        textSecondary,
      ));
    }

    if (s.availability > 0) {
      rows.add(_row(
        'Availability',
        '${s.availability.toStringAsFixed(2)} copies',
        orangeClr,
        Icons.layers_outlined,
        textSecondary,
      ));
    }

    return Container(
      padding: const EdgeInsets.all(DmxTokens.spaceMd),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor(isDark),
        borderRadius: BorderRadius.circular(DmxTokens.radiusLg),
        border: Border.all(
          color: AppTheme.hairlineBorder(isDark),
          width: DmxTokens.borderThin,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ...rows,
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.surfaceColor(isDark, elevated: true),
              borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 14, color: textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Per-peer details are not reported by the torrent engine on this '
                    'platform; aggregate swarm counts are shown instead.',
                    style: TextStyle(
                      fontFamily: AppTheme.fontBody,
                      fontSize: DmxTokens.textXs,
                      color: textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
    String label,
    String value,
    Color accent,
    IconData icon,
    Color labelColor,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5.0),
      child: Row(
        children: [
          Icon(icon, size: 15, color: accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: AppTheme.fontBody,
                fontSize: DmxTokens.textSm,
                color: labelColor,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(
              fontFamily: AppTheme.fontDisplay,
              fontSize: DmxTokens.textSm,
              fontWeight: FontWeight.w700,
              color: accent,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
