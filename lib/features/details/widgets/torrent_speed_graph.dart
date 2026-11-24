import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/app_theme.dart';
import '../../../shared/design/dmx_tokens.dart';

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

  String _formatSpeed(double bps) {
    if (!bps.isFinite || bps <= 0) return '0 B/s';
    final kb = bps / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB/s';
    return '${(kb / 1024).toStringAsFixed(1)} MB/s';
  }

  @override
  Widget build(BuildContext context) {
    final dlColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final ulColor = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final textSecondary = AppTheme.textSecondaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);
    final gridColor = AppTheme.hairlineBorder(isDark);

    final latestDl = downloadSpeeds.isNotEmpty ? downloadSpeeds.last : 0.0;
    final latestUl = uploadSpeeds.isNotEmpty ? uploadSpeeds.last : 0.0;

    double peakBps = 0.0;
    for (final v in downloadSpeeds) {
      if (v.isFinite && v > peakBps) peakBps = v;
    }
    for (final v in uploadSpeeds) {
      if (v.isFinite && v > peakBps) peakBps = v;
    }
    final maxY = math.max(10.0, (peakBps / 1024) * 1.15);

    return Container(
      height: 156,
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
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _LegendItem(
                      color: dlColor,
                      label: 'Download',
                      value: _formatSpeed(latestDl),
                      isDark: isDark,
                    ),
                    _LegendItem(
                      color: ulColor,
                      label: 'Upload',
                      value: _formatSpeed(latestUl),
                      isDark: isDark,
                    ),
                  ],
                ),
              ),
              if (peakBps > 0) ...[
                const SizedBox(width: 8),
                Text(
                  'Peak ${_formatSpeed(peakBps)}',
                  style: TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: textMuted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ] else
                Text(
                  'IDLE',
                  style: TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: textSecondary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LineChart(
              LineChartData(
                minY: 0,
                maxY: maxY,
                clipData: const FlClipData.all(),
                lineBarsData: [
                  _buildLine(downloadSpeeds, dlColor),
                  _buildLine(uploadSpeeds, ulColor),
                ],
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: maxY / 3,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: gridColor,
                    strokeWidth: 0.8,
                    dashArray: const [4, 4],
                  ),
                ),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                lineTouchData: const LineTouchData(enabled: false),
              ),
              duration: Duration.zero,
            ),
          ),
        ],
      ),
    );
  }

  LineChartBarData _buildLine(List<double> data, Color color) {
    if (data.isEmpty) {
      return LineChartBarData(
        spots: const [FlSpot(0, 0), FlSpot(1, 0)],
        color: color.withValues(alpha: 0.45),
        barWidth: 1.8,
        dotData: const FlDotData(show: false),
      );
    }
    final spots = data
        .asMap()
        .entries
        .map((e) => FlSpot(
              e.key.toDouble(),
              (e.value.isFinite && e.value >= 0) ? e.value / 1024 : 0.0,
            ))
        .toList();
    if (spots.length == 1) {
      spots.add(FlSpot(1, spots.first.y));
    }
    return LineChartBarData(
      spots: spots,
      isCurved: spots.length > 2,
      curveSmoothness: 0.28,
      preventCurveOverShooting: true,
      color: color,
      barWidth: 2.2,
      isStrokeCapRound: true,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(
        show: true,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: isDark ? 0.22 : 0.16),
            color.withValues(alpha: 0.0),
          ],
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  final String value;
  final bool isDark;

  const _LegendItem({
    required this.color,
    required this.label,
    required this.value,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontFamily: AppTheme.fontDisplay,
            fontSize: DmxTokens.textXs,
            fontWeight: FontWeight.w600,
            color: AppTheme.textMutedOf(isDark),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          value,
          style: TextStyle(
            fontFamily: AppTheme.fontDisplay,
            fontSize: DmxTokens.textXs,
            fontWeight: FontWeight.w700,
            color: AppTheme.textPrimaryOf(isDark),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
