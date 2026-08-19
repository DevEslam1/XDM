import 'package:flutter/foundation.dart';
import '../models/download_task.dart';
import 'download_list_provider.dart';

/// Aggregates performance statistics, active download counts, and speeds
/// for dashboard and telemetry widgets without triggering list item rebuilds.
class DownloadStatsNotifier extends ChangeNotifier {
  final DownloadListProvider _listProvider;

  int _activeCount = 0;
  int _completedCount = 0;
  int _failedCount = 0;
  double _totalDownloadSpeed = 0.0;
  double _totalUploadSpeed = 0.0;
  int _totalDownloadedBytes = 0;

  DownloadStatsNotifier(this._listProvider) {
    _listProvider.addListener(recalculate);
    recalculate();
  }

  int get activeCount => _activeCount;
  int get completedCount => _completedCount;
  int get failedCount => _failedCount;
  double get totalDownloadSpeed => _totalDownloadSpeed;
  double get totalUploadSpeed => _totalUploadSpeed;
  int get totalDownloadedBytes => _totalDownloadedBytes;

  void recalculate() {
    final tasks = _listProvider.tasks;
    var active = 0;
    var completed = 0;
    var failed = 0;
    var speed = 0.0;
    var upload = 0.0;
    var bytes = 0;

    for (final t in tasks) {
      if (t.status == DownloadStatus.downloading) {
        active++;
        speed += t.speed;
      } else if (t.status == DownloadStatus.completed) {
        completed++;
        if (t.isTorrent && t.seedingEnabled) {
          upload += t.speed;
        }
      } else if (t.status == DownloadStatus.failed) {
        failed++;
      }
      bytes += t.downloadedBytes;
    }

    if (_activeCount != active ||
        _completedCount != completed ||
        _failedCount != failed ||
        _totalDownloadSpeed != speed ||
        _totalUploadSpeed != upload ||
        _totalDownloadedBytes != bytes) {
      _activeCount = active;
      _completedCount = completed;
      _failedCount = failed;
      _totalDownloadSpeed = speed;
      _totalUploadSpeed = upload;
      _totalDownloadedBytes = bytes;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _listProvider.removeListener(recalculate);
    super.dispose();
  }
}
