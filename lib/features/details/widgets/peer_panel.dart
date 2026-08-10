import 'package:flutter/material.dart';
import '../../../core/app_theme.dart';

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
  final String flags;

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
    required this.flags,
  });
}

class PeerPanel extends StatelessWidget {
  final int torrentId;
  final bool isDark;
  final List<PeerInfo> peers;

  const PeerPanel({
    super.key,
    required this.torrentId,
    required this.isDark,
    this.peers = const [],
  });

  String _formatSpeed(int bps) {
    if (bps <= 0) return '0 B/s';
    final kb = bps / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB/s';
    return '${(kb / 1024).toStringAsFixed(1)} MB/s';
  }

  @override
  Widget build(BuildContext context) {
    final seeds = peers.where((p) => p.isSeed).length;
    final leeches = peers.where((p) => !p.isSeed).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                'Peers (${peers.length})',
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
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                ),
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (peers.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20.0),
            child: Center(
              child: Text(
                'No peer connections currently active.',
                style: TextStyle(color: AppTheme.textMuted),
              ),
            ),
          )
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
                leading: Icon(
                  peer.isEncrypted ? Icons.lock_outline : Icons.link_rounded,
                  size: 16,
                  color: peer.isSeed ? AppTheme.neonGreen : AppTheme.neonBlue,
                ),
                title: Text(peer.country.isEmpty
                    ? '${peer.ip}:${peer.port}'
                    : '${peer.ip}:${peer.port} (${peer.country})'),
                subtitle: Text(
                    '${peer.client} • ${(peer.progress * 100).toStringAsFixed(0)}%'),
                trailing: Text(
                    '↓ ${_formatSpeed(peer.downloadSpeed)}  ↑ ${_formatSpeed(peer.uploadSpeed)}'),
              );
            },
          ),
      ],
    );
  }
}
