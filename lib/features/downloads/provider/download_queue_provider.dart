import 'package:flutter/foundation.dart';

import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';
import 'download_list_provider.dart';

/// Single-responsibility provider managing execution queue and concurrency.
class DownloadQueueProvider extends ChangeNotifier {
  final DownloadListProvider? _listProvider;
  final SettingsProvider? _settings;
  final int? _maxConcurrentOverride;

  final List<String> _queuedIds = [];

  DownloadQueueProvider({
    DownloadListProvider? listProvider,
    SettingsProvider? settings,
    int? maxConcurrentDownloads,
  })  : _listProvider = listProvider,
        _settings = settings,
        _maxConcurrentOverride = maxConcurrentDownloads;

  int get maxConcurrentDownloads =>
      _maxConcurrentOverride ?? _settings?.maxDownloads ?? 3;
  List<String> get queueTaskIds => List.unmodifiable(_queuedIds);

  void addToQueue(String taskId) {
    if (!_queuedIds.contains(taskId)) {
      _queuedIds.add(taskId);
      notifyListeners();
    }
  }

  void pumpQueue() {
    final list = _listProvider;
    if (list == null) return;
    final activeCount =
        list.tasks.where((t) => t.status == DownloadStatus.downloading).length;
    final maxConcurrent = maxConcurrentDownloads;

    if (activeCount >= maxConcurrent) return;

    final queued =
        list.tasks.where((t) => t.status == DownloadStatus.queued).toList();

    for (final task in queued) {
      if (activeCount >= maxConcurrent) break;
      list.updateTask(task.copyWith(status: DownloadStatus.downloading));
    }
  }

  Future<void> pauseTask(String id, {PauseReason reason = PauseReason.userRequested}) async {
    final list = _listProvider;
    if (list == null) return;
    final task = list.findTask(id);
    if (task != null && task.status == DownloadStatus.downloading) {
      await list.updateTask(
        task.copyWith(status: DownloadStatus.paused, pausedByUser: reason == PauseReason.userRequested),
      );
      pumpQueue();
    }
  }

  Future<void> resumeTask(String id) async {
    final list = _listProvider;
    if (list == null) return;
    final task = list.findTask(id);
    if (task != null && task.status == DownloadStatus.paused) {
      await list.updateTask(
        task.copyWith(status: DownloadStatus.queued, pausedByUser: false),
      );
      pumpQueue();
    }
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _queuedIds.length) return;
    if (newIndex < 0 || newIndex > _queuedIds.length) return;
    final item = _queuedIds.removeAt(oldIndex);
    _queuedIds.insert(newIndex, item);
    notifyListeners();
  }
}
