import 'dart:async';
import 'package:flutter/material.dart';
import 'package:dmx/core/app_theme.dart';
import 'package:dmx/shared/design/dmx_design.dart';

enum TorrentMetadataState {
  connecting,
  addingTrackers,
  fetchingMetadata,
  failed,
  completed,
}

class TorrentMetadataProgress extends StatefulWidget {
  const TorrentMetadataProgress({
    super.key,
    required this.magnetUri,
    this.peersCount = 0,
    this.dhtNodes = 0,
    this.state = TorrentMetadataState.fetchingMetadata,
    this.errorMessage,
    this.onCancel,
    this.onRetry,
  });

  final String magnetUri;
  final int peersCount;
  final int dhtNodes;
  final TorrentMetadataState state;
  final String? errorMessage;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;

  @override
  State<TorrentMetadataProgress> createState() =>
      _TorrentMetadataProgressState();
}

class _TorrentMetadataProgressState extends State<TorrentMetadataProgress> {
  late Stopwatch _stopwatch;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _stopwatch = Stopwatch()..start();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stopwatch.stop();
    super.dispose();
  }

  String _formatElapsed() {
    final secs = _stopwatch.elapsed.inSeconds;
    final m = secs ~/ 60;
    final s = secs % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _getStateLabel() {
    switch (widget.state) {
      case TorrentMetadataState.connecting:
        return 'Connecting to peers...';
      case TorrentMetadataState.addingTrackers:
        return 'Adding trackers...';
      case TorrentMetadataState.fetchingMetadata:
        return 'Fetching torrent metadata...';
      case TorrentMetadataState.failed:
        return widget.errorMessage ?? 'Failed to fetch metadata';
      case TorrentMetadataState.completed:
        return 'Metadata received';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = widget.state == TorrentMetadataState.failed
        ? (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
        : (isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber);

    return DmxCardShell(
      accent: accentColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: widget.state == TorrentMetadataState.failed
                      ? Icon(Icons.error_outline_rounded,
                          color: accentColor, size: 24)
                      : CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(accentColor),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _getStateLabel(),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Elapsed time: ${_formatElapsed()}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white60 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.onCancel != null)
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: widget.onCancel,
                    tooltip: 'Cancel',
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildTelemetryChip(
                  icon: Icons.people_outline_rounded,
                  label: 'Peers',
                  value: '${widget.peersCount}',
                  color: accentColor,
                  isDark: isDark,
                ),
                _buildTelemetryChip(
                  icon: Icons.hub_outlined,
                  label: 'DHT Nodes',
                  value: '${widget.dhtNodes}',
                  color: accentColor,
                  isDark: isDark,
                ),
              ],
            ),
            if (widget.state == TorrentMetadataState.failed &&
                widget.onRetry != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: widget.onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Retry Fetching Metadata'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTelemetryChip({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: isDark ? Colors.white60 : Colors.black54,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
