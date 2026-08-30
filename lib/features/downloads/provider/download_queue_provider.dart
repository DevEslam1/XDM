import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';
import 'download_list_provider.dart';
import 'download_queue_engine.dart';

/// Single-responsibility provider managing execution queue and concurrency.
class DownloadQueueProvider extends ChangeNotifier {
  final DownloadListProvider? _listProvider;
  final SettingsProvider? _settings;
  final int? _maxConcurrentOverride;
  final DownloadQueueEngine _engine = DownloadQueueEngine();

  final List<String> _queuedIds = [];
  Timer? _debounceTimer;
  bool _disposed = false;

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
    if (_disposed) return;
    if (!_queuedIds.contains(taskId)) {
      _queuedIds.add(taskId);
      notifyListeners();
    }
  }

  void pumpQueue() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 50), () async {
      if (_disposed) return;
      final list = _listProvider;
      if (list == null) return;
      _engine.maxConcurrent = maxConcurrentDownloads;
      _engine.pumpQueue(list.tasks, (task) async {
        if (_disposed) return;
        if (DownloadStateMachine.canTransitionStatus(
            task.status, DownloadStatus.downloading)) {
          final updated = task.transitionTo(DownloadStatus.downloading);
          await list.updateTask(updated);
        }
      });
    });
  }

  Future<void> pauseTask(String id,
      {PauseReason reason = PauseReason.userRequested}) async {
    if (_disposed) return;
    final list = _listProvider;
    if (list == null) return;
    final task = list.findTask(id);
    if (task != null &&
        DownloadStateMachine.canTransitionStatus(
            task.status, DownloadStatus.paused)) {
      final updated = task
          .transitionTo(DownloadStatus.paused, reason: reason.name)
          .copyWith(pauseReason: reason);
      await list.updateTask(updated);
      pumpQueue();
    }
  }

  Future<void> resumeTask(String id) async {
    if (_disposed) return;
    final list = _listProvider;
    if (list == null) return;
    final task = list.findTask(id);
    if (task != null &&
        DownloadStateMachine.canTransitionStatus(
            task.status, DownloadStatus.queued)) {
      final updated = task.transitionTo(DownloadStatus.queued);
      await list.updateTask(updated);
      pumpQueue();
    }
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (_disposed) return;
    if (oldIndex < 0 || oldIndex >= _queuedIds.length) return;
    if (newIndex < 0 || newIndex > _queuedIds.length) return;
    final item = _queuedIds.removeAt(oldIndex);
    _queuedIds.insert(newIndex, item);
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    super.dispose();
  }
}
