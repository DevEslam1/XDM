import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:dmx/core/app_theme.dart';
import 'package:dmx/core/utils/file_utils.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/shared/design/dmx_design.dart';

class SpeedGraphWidget extends StatelessWidget {
  const SpeedGraphWidget({
    super.key,
    required this.speedHistory,
    this.status = DownloadStatus.downloading,
    this.height = 180,
  });

  /// Up to 60 data points representing bytes/sec over the last 60 seconds
  final List<int> speedHistory;
  final DownloadStatus status;
  final double height;

  Color _getStatusColor(bool isDark) {
    switch (status) {
      case DownloadStatus.downloading:
        return isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
      case DownloadStatus.paused:
        return Colors.grey;
      case DownloadStatus.failed:
        return isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
      case DownloadStatus.completed:
        return isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
      default:
        return Colors.blue;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = _getStatusColor(isDark);

    // Prepare 60 data points (padded with zeros if history is shorter)
    final displayHistory = speedHistory.length < 60
        ? [...List.filled(60 - speedHistory.length, 0), ...speedHistory]
        : speedHistory.sublist(speedHistory.length - 60);

    final currentSpeed = displayHistory.isNotEmpty ? displayHistory.last : 0;
    final peakSpeed = displayHistory.isNotEmpty
        ? displayHistory.reduce((a, b) => max(a, b))
        : 0;
    final nonZero = displayHistory.where((s) => s > 0);
    final avgSpeed = nonZero.isNotEmpty
        ? (nonZero.reduce((a, b) => a + b) / nonZero.length).round()
        : 0;

    final maxY = max(100 * 1024, (peakSpeed * 1.2).toDouble());

    final spots = List.generate(
      displayHistory.length,
      (i) => FlSpot(i.toDouble(), displayHistory[i].toDouble()),
    );

    return RepaintBoundary(
      child: DmxCardShell(
        accent: color,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.speed_rounded, color: color, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Download Speed (60s)',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '${formatBytes(currentSpeed)}/s',
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildStatItem('Current', '${formatBytes(currentSpeed)}/s',
                      color, isDark),
                  _buildStatItem('Average', '${formatBytes(avgSpeed)}/s',
                      Colors.grey, isDark),
                  _buildStatItem('Peak', '${formatBytes(peakSpeed)}/s',
                      Colors.amber, isDark),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: height,
                child: LineChart(
                  LineChartData(
                    minX: 0,
                    maxX: 59,
                    minY: 0,
                    maxY: maxY.toDouble(),
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      getDrawingHorizontalLine: (value) => FlLine(
                        color: isDark ? Colors.white10 : Colors.black12,
                        strokeWidth: 1,
                      ),
                    ),
                    titlesData: FlTitlesData(
                      show: true,
                      topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 20,
                          interval: 15,
                          getTitlesWidget: (value, meta) {
                            final secs = 60 - value.toInt();
                            if (secs == 60) {
                              return const Text('60s',
                                  style: TextStyle(fontSize: 10));
                            }
                            if (secs == 30) {
                              return const Text('30s',
                                  style: TextStyle(fontSize: 10));
                            }
                            if (secs == 0) {
                              return const Text('now',
                                  style: TextStyle(fontSize: 10));
                            }
                            return const Text('');
                          },
                        ),
                      ),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 50,
                          getTitlesWidget: (value, meta) {
                            if (value == 0) {
                              return const Text('0',
                                  style: TextStyle(fontSize: 9));
                            }
                            if (value == maxY) {
                              return Text(
                                formatBytes(value.toInt()),
                                style: const TextStyle(fontSize: 9),
                              );
                            }
                            return const Text('');
                          },
                        ),
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    lineBarsData: [
                      LineChartBarData(
                        spots: spots,
                        isCurved: true,
                        color: color,
                        barWidth: 2.5,
                        isStrokeCapRound: true,
                        dotData: const FlDotData(show: false),
                        belowBarData: BarAreaData(
                          show: true,
                          color: color.withValues(alpha: 0.15),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatItem(
      String label, String value, Color labelColor, bool isDark) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isDark ? Colors.white60 : Colors.black54,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: labelColor,
          ),
        ),
      ],
    );
  }
}
