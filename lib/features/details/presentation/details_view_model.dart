import 'dart:async';
import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/widgets.dart';

import '../../../core/services/engine/torrent_file_normalizer.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/localization.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';

/// ViewModel managing state, metrics caching, and speed history for the Details screen.
class DetailsViewModel extends ChangeNotifier {
  final String taskId;
  final DownloadProvider downloadProvider;

  bool _disposed = false;
  DateTime _lastSpeedUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  List<FlSpot> _downloadSpots = const [];
  List<FlSpot> _uploadSpots = const [];
  int _maxGraphLen = 1;
  Timer? _speedRefreshTimer;

  bool get isDisposed => _disposed;

  DetailsViewModel({
    required this.taskId,
    required this.downloadProvider,
  }) {
    updateSpeedSpots();
    _speedRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (task == null) {
        _speedRefreshTimer?.cancel();
        _speedRefreshTimer = null;
        return;
      }
      updateSpeedSpots();
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _speedRefreshTimer?.cancel();
    _speedRefreshTimer = null;
    super.dispose();
  }

  DownloadTask? get task {
    final matches = downloadProvider.tasks.where((t) => t.id == taskId);
    return matches.isNotEmpty ? matches.first : null;
  }

  List<FlSpot> get downloadSpots => _downloadSpots;
  List<FlSpot> get uploadSpots => _uploadSpots;
  int get maxGraphLen => _maxGraphLen;

  bool get isSeeding {
    final t = task;
    if (t == null) return false;
    return t.status == DownloadStatus.completed &&
        t.isTorrent &&
        t.seedingEnabled;
  }

  String speedText(BuildContext context) {
    final t = task;
    if (t == null) return '';
    final isDownloadingTorrent =
        t.status == DownloadStatus.downloading && t.isTorrent;
    if (isDownloadingTorrent) {
      final ulSpeed = downloadProvider.getTorrentUploadSpeed(t.id);
      return 'DL: ${t.speedFormatted} | UL: ${formatBytes(ulSpeed)}/s';
    } else if (isSeeding) {
      final ulSpeed = downloadProvider.getTorrentUploadSpeed(t.id);
      return 'UL: ${formatBytes(ulSpeed)}/s';
    } else {
      return t.status == DownloadStatus.downloading
          ? t.speedFormatted
          : L10n.translateStatusName(context, t.status).toUpperCase();
    }
  }

  String etaText(BuildContext context) {
    final t = task;
    if (t == null) return '';
    if (isSeeding) {
      return downloadProvider.getSeedingSummary(t.id);
    } else if (t.status == DownloadStatus.downloading) {
      return L10n.translateStatus(context, t.status, t.etaFormatted);
    } else {
      return L10n.of(context, 'details_inactive_eta');
    }
  }

  // FIX: [Audit] Deduplicated filesLabel using centralized TorrentFileNormalizer helper
  String filesLabel() {
    final t = task;
    if (t == null) return '—';
    if (!t.isTorrent) return '${t.threadCount} CH';
    final files = t.torrentFiles;
    if (files != null && files.isNotEmpty) {
      return TorrentFileNormalizer.formatSummaryFromFiles(files);
    }
    final total = t.totalFiles ?? 0;
    final completed = t.completedFiles ?? 0;
    return TorrentFileNormalizer.formatFilesSummary(
      totalFiles: total,
      completedFiles: completed,
    );
  }

  static bool _spotsEqual(List<FlSpot> a, List<FlSpot> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].x != b[i].x || a[i].y != b[i].y) return false;
    }
    return true;
  }

  // FIX: [Audit] Optimize 1s timer: only notify listeners if speed history spots actually changed
  void updateSpeedSpots() {
    if (_disposed) return;
    final now = DateTime.now();
    if (_downloadSpots.isNotEmpty &&
        now.difference(_lastSpeedUpdate) < const Duration(seconds: 1)) {
      return;
    }
    _lastSpeedUpdate = now;
    final dlH = downloadProvider.getSpeedHistory(taskId);
    final ulH = downloadProvider.getUploadSpeedHistory(taskId);
    final len = math.max(dlH.length, ulH.length);

    List<FlSpot> align(List<double> h) => [
          for (var i = 0; i < h.length; i++)
            FlSpot((len - h.length + i).toDouble(), h[i]),
        ];

    var dl = align(dlH);
    var ul = align(ulH);
    if (len == 1) {
      dl = [
        FlSpot(0, dlH.isNotEmpty ? dlH[0] : 0),
        FlSpot(1, dlH.isNotEmpty ? dlH[0] : 0)
      ];
      ul = [
        FlSpot(0, ulH.isNotEmpty ? ulH[0] : 0),
        FlSpot(1, ulH.isNotEmpty ? ulH[0] : 0)
      ];
    }
    final changed =
        !_spotsEqual(_downloadSpots, dl) || !_spotsEqual(_uploadSpots, ul);
    _downloadSpots = dl;
    _uploadSpots = ul;
    _maxGraphLen = math.max(len, 1);
    if (changed) {
      notifyListeners();
    }
  }
}
