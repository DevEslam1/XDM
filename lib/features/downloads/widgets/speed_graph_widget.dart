import 'dart:math';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:dmx/core/app_theme.dart';
import 'package:dmx/core/utils/file_utils.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/shared/design/dmx_design.dart';

class SpeedGraphWidget extends StatefulWidget {
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

  @override
  State<SpeedGraphWidget> createState() => _SpeedGraphWidgetState();
}

class _SpeedGraphWidgetState extends State<SpeedGraphWidget> {
  List<int>? _lastSpeedHistory;
  List<int> _displayHistory = [];
  bool? _lastIsDark;
  DownloadStatus? _lastStatus;
  int _lastCurrentSpeed = 0;
  int _lastAvgSpeed = 0;
  int _lastPeakSpeed = 0;
  double _maxY = 100 * 1024;
  Color _lastColor = Colors.blue;

  Color _getStatusColor(DownloadStatus status, bool isDark) {
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

  void _updateCache(bool isDark) {
    _lastIsDark = isDark;
    _lastStatus = widget.status;
    _lastSpeedHistory = List<int>.from(widget.speedHistory);
    final color = _getStatusColor(widget.status, isDark);
    _lastColor = color;

    // Cap the rolling sample buffer at 60 entries (1 minute @ 1Hz)
    _displayHistory = widget.speedHistory.length > 60
        ? widget.speedHistory.sublist(widget.speedHistory.length - 60)
        : (widget.speedHistory.length < 60
            ? [
                ...List.filled(60 - widget.speedHistory.length, 0),
                ...widget.speedHistory,
              ]
            : widget.speedHistory);

    _lastCurrentSpeed = _displayHistory.isNotEmpty ? _displayHistory.last : 0;
    _lastPeakSpeed = _displayHistory.isNotEmpty
        ? _displayHistory.reduce((a, b) => max(a, b))
        : 0;
    final nonZero = _displayHistory.where((s) => s > 0);
    _lastAvgSpeed = nonZero.isNotEmpty
        ? (nonZero.reduce((a, b) => a + b) / nonZero.length).round()
        : 0;

    _maxY = max(100 * 1024, (_lastPeakSpeed * 1.2).toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_lastIsDark != isDark ||
        _lastStatus != widget.status ||
        !listEquals(_lastSpeedHistory, widget.speedHistory)) {
      _updateCache(isDark);
    }

    final color = _lastColor;
    final currentSpeed = _lastCurrentSpeed;
    final avgSpeed = _lastAvgSpeed;
    final peakSpeed = _lastPeakSpeed;

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
                height: widget.height,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _SpeedGraphPainter(
                      samples: _displayHistory,
                      color: color,
                      isDark: isDark,
                      maxY: _maxY,
                    ),
                    size: Size(double.infinity, widget.height),
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

class _SpeedGraphPainter extends CustomPainter {
  final List<int> samples;
  final Color color;
  final bool isDark;
  final double maxY;
  final int samplesHash;

  _SpeedGraphPainter({
    required this.samples,
    required this.color,
    required this.isDark,
    required this.maxY,
  }) : samplesHash = Object.hashAll(samples);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || samples.isEmpty) return;

    final gridPaint = Paint()
      ..color = isDark ? Colors.white10 : Colors.black12
      ..strokeWidth = 1.0;
    canvas.drawLine(
        Offset(0, size.height * 0.5), Offset(size.width, size.height * 0.5), gridPaint);
    canvas.drawLine(
        Offset(0, size.height), Offset(size.width, size.height), gridPaint);

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.25),
          color.withValues(alpha: 0.0),
        ],
      ).createShader(Offset.zero & size)
      ..style = PaintingStyle.fill;

    final path = Path();
    final fillPath = Path();
    final stepX = size.width / (samples.length - 1);

    for (int i = 0; i < samples.length; i++) {
      final x = i * stepX;
      final y =
          size.height - ((samples[i] / maxY).clamp(0.0, 1.0) * (size.height - 4) + 2);
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _SpeedGraphPainter oldDelegate) {
    return oldDelegate.samplesHash != samplesHash ||
        oldDelegate.color != color ||
        oldDelegate.isDark != isDark ||
        oldDelegate.maxY != maxY;
  }
}
