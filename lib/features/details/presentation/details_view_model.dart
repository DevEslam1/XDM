import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/widgets.dart';

import '../../../core/utils/file_utils.dart';
import '../../../core/utils/localization.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';

/// ViewModel managing state, metrics caching, and speed history for the Details screen.
class DetailsViewModel extends ChangeNotifier {
  final String taskId;
  final DownloadProvider downloadProvider;

  DateTime _lastSpeedUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  List<FlSpot> _downloadSpots = const [];
  List<FlSpot> _uploadSpots = const [];
  int _maxGraphLen = 1;

  DetailsViewModel({
    required this.taskId,
    required this.downloadProvider,
  });

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

  String filesLabel() {
    final t = task;
    if (t == null) return '—';
    if (!t.isTorrent) return '${t.threadCount} CH';
    final files = t.torrentFiles;
    if (files != null && files.isNotEmpty) {
      final selected =
          files.where((f) => (f['selected'] as bool?) ?? true).toList();
      if (selected.isEmpty) return '—';
      final completed = selected.where((f) => f['isComplete'] == true).length;
      return selected.length == files.length
          ? (completed > 0
              ? '$completed/${files.length} FILES'
              : '${files.length} FILES')
          : '$completed/${selected.length} FILES';
    }
    final total = t.totalFiles ?? 0;
    final completed = t.completedFiles ?? 0;
    if (total > 0) {
      return completed > 0 ? '$completed/$total FILES' : '$total FILES';
    }
    return '—';
  }

  void updateSpeedSpots() {
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
    _downloadSpots = dl;
    _uploadSpots = ul;
    _maxGraphLen = math.max(len, 1);
    notifyListeners();
  }
}
