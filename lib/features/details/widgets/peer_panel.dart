import 'package:flutter/material.dart';
import '../../../core/app_theme.dart';
import '../../../core/domain/torrent_models.dart';

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
    final textMuted = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
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
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                'Peers ($connectionCount)',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color:
                      isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Seeds: $seeds | Leeches: $leeches',
                style: TextStyle(fontSize: 12, color: textMuted),
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (peers.isEmpty)
          _SwarmSummary(swarm: s, isDark: isDark)
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: peers.length,
            itemBuilder: (context, index) {
              final peer = peers[index];
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      peer.isEncrypted
                          ? Icons.lock_outline
                          : Icons.link_rounded,
                      size: 16,
                      color:
                          peer.isSeed ? AppTheme.neonGreen : AppTheme.neonBlue,
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      peer.isOutgoing ? Icons.north_east : Icons.south_west,
                      size: 12,
                      color: textMuted,
                    ),
                  ],
                ),
                title: Text(peer.country.isEmpty
                    ? '${peer.ip}:${peer.port}'
                    : '${peer.ip}:${peer.port} (${peer.country})'),
                subtitle: Text(
                    '${peer.client.isNotEmpty ? peer.client : 'Peer'} • ${(peer.progress * 100).toStringAsFixed(0)}% • Quality: ${(peer.relevance * 100).toStringAsFixed(0)}%'),
                trailing: Text(
                    '↓ ${_formatSpeed(peer.downloadSpeed)}  ↑ ${_formatSpeed(peer.uploadSpeed)}'),
              );
            },
          ),
      ],
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
    final textMuted = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final s = swarm;

    if (s == null || s.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20.0),
        child: Center(
          child: Text(
            'No peer connections currently active.',
            style: TextStyle(color: textMuted),
          ),
        ),
      );
    }

    final rows = <Widget>[
      _row('Connected seeds', '${s.connectedSeeds}', AppTheme.neonGreen,
          Icons.cloud_download_outlined, textMuted),
      _row('Connected peers', '${s.connectedPeers}', AppTheme.neonBlue,
          Icons.people_outline, textMuted),
    ];

    if (s.hasSwarmScrape) {
      // Tracker scrape totals describe the whole swarm, not this session's
      // connections, so they are labelled separately.
      rows.add(_row(
        'Swarm (tracker)',
        '${s.swarmSeeds ?? '—'} seeds · ${s.swarmPeers ?? '—'} peers',
        AppTheme.neonViolet,
        Icons.public_outlined,
        textMuted,
      ));
    }

    if (s.availability > 0) {
      rows.add(_row(
          'Availability',
          '${s.availability.toStringAsFixed(2)} copies',
          AppTheme.neonOrange,
          Icons.layers_outlined,
          textMuted));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...rows,
        const SizedBox(height: 6),
        Text(
          'Per-peer details are not reported by the torrent engine on this '
          'platform; aggregate swarm counts are shown instead.',
          style: TextStyle(fontSize: 11, color: textMuted),
        ),
      ],
    );
  }

  Widget _row(String label, String value, Color accent, IconData icon,
      Color labelColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Icon(icon, size: 14, color: accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: labelColor),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}
