import 'package:flutter/material.dart';
import '../../../core/app_theme.dart';

enum HealthLevel {
  dead(Color(0xFFEF4444), Icons.signal_cellular_off_rounded,
      'No seeds, no peers'),
  poor(Color(0xFFF97316), Icons.signal_cellular_alt_1_bar_rounded,
      'Few peers, slow'),
  fair(Color(0xFFF59E0B), Icons.signal_cellular_alt_2_bar_rounded,
      'Moderate availability'),
  good(Color(0xFF22C55E), Icons.signal_cellular_alt_rounded,
      'Good availability'),
  excellent(
      Color(0xFF10B981), Icons.signal_cellular_alt_rounded, 'Excellent, fast');

  final Color color;
  final IconData icon;
  final String label;
  const HealthLevel(this.color, this.icon, this.label);
}

HealthLevel calculateHealth({
  required int seeds,
  required int peers,
  required double availability,
  required double distributedCopies,
  required double downloadRate,
}) {
  // If data is actively flowing, the torrent is NOT dead — there must be at
  // least one peer or web-seed connected even if the reported count is 0.
  if (seeds <= 0 && peers <= 0 && downloadRate <= 0) return HealthLevel.dead;
  if (seeds >= 10 && downloadRate > 100 * 1024) return HealthLevel.excellent;
  if (seeds >= 3 || downloadRate > 20 * 1024) return HealthLevel.good;
  if (seeds > 0 || peers > 0 || downloadRate > 0) return HealthLevel.fair;
  if (availability < 1.0 && distributedCopies < 1.0) return HealthLevel.poor;
  return HealthLevel.good;
}

class TorrentHealthIndicator extends StatelessWidget {
  final double availability;
  final double distributedCopies;
  final int seeds;
  final int peers;
  final double downloadRate;
  final bool isDark;

  const TorrentHealthIndicator({
    super.key,
    required this.availability,
    required this.distributedCopies,
    required this.seeds,
    required this.peers,
    this.downloadRate = 0.0,
    required this.isDark,
  });

  HealthLevel get _level => calculateHealth(
        seeds: seeds,
        peers: peers,
        availability: availability,
        distributedCopies: distributedCopies,
        downloadRate: downloadRate,
      );

  @override
  Widget build(BuildContext context) {
    final level = _level;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: level.color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: level.color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(level.icon, size: 14, color: level.color),
          const SizedBox(width: 6),
          Text(
            level.name.toUpperCase(),
            style: TextStyle(
                color: level.color, fontSize: 10, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 8),
          Text(
            level.label,
            style: TextStyle(
                color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                fontSize: 9),
          ),
        ],
      ),
    );
  }
}
