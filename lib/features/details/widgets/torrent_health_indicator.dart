import 'package:flutter/material.dart';
import '../../../core/app_theme.dart';

enum HealthLevel {
  dead(Color(0xFFEF4444), Icons.signal_cellular_off_rounded, 'DEAD'),
  poor(Color(0xFFF97316), Icons.signal_cellular_alt_1_bar_rounded, 'POOR'),
  fair(Color(0xFFF59E0B), Icons.signal_cellular_alt_2_bar_rounded, 'FAIR'),
  good(Color(0xFF22C55E), Icons.signal_cellular_alt_rounded, 'GOOD'),
  excellent(Color(0xFF10B981), Icons.signal_cellular_alt_rounded, 'EXCELLENT');

  final Color color;
  final IconData icon;
  final String label;
  const HealthLevel(this.color, this.icon, this.label);
}

class TorrentHealthIndicator extends StatelessWidget {
  final double availability;
  final double distributedCopies;
  final int seeds;
  final int peers;
  final bool isDark;

  const TorrentHealthIndicator({
    super.key,
    required this.availability,
    required this.distributedCopies,
    required this.seeds,
    required this.peers,
    required this.isDark,
  });

  HealthLevel get _level {
    if (seeds == 0 && availability < 1.0) return HealthLevel.dead;
    if (seeds == 0 && availability >= 1.0) return HealthLevel.poor;
    if (seeds < 3) return HealthLevel.fair;
    if (seeds < 10) return HealthLevel.good;
    return HealthLevel.excellent;
  }

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
            level.label,
            style: TextStyle(color: level.color, fontSize: 10, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 8),
          Text(
            'AVAIL: ${availability.toStringAsFixed(2)}',
            style: TextStyle(color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted, fontSize: 9),
          ),
        ],
      ),
    );
  }
}
