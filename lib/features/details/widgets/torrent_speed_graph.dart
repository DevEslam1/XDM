import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../../core/app_theme.dart';

class TorrentSpeedGraph extends StatelessWidget {
  final List<double> downloadSpeeds;
  final List<double> uploadSpeeds;
  final bool isDark;

  const TorrentSpeedGraph({
    super.key,
    required this.downloadSpeeds,
    required this.uploadSpeeds,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:
            (isDark ? AppTheme.surface : Colors.white).withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildDot(AppTheme.neonBlue, 'Download'),
              const SizedBox(width: 12),
              _buildDot(AppTheme.neonGreen, 'Upload'),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: LineChart(
              LineChartData(
                lineBarsData: [
                  _buildLine(downloadSpeeds, AppTheme.neonBlue),
                  _buildLine(uploadSpeeds, AppTheme.neonGreen),
                ],
                gridData: const FlGridData(show: false),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                lineTouchData: const LineTouchData(enabled: false),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDot(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
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

  LineChartBarData _buildLine(List<double> data, Color color) {
    if (data.isEmpty) {
      return LineChartBarData(
        spots: const [FlSpot(0, 0)],
        color: color,
        barWidth: 2,
      );
    }
    return LineChartBarData(
      spots: data
          .asMap()
          .entries
          .map((e) => FlSpot(e.key.toDouble(), e.value / 1024))
          .toList(),
      isCurved: true,
      color: color,
      barWidth: 2,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(
        show: true,
        color: color.withValues(alpha: 0.1),
      ),
    );
  }
}
