import 'package:flutter/foundation.dart';
import '../models/download_task.dart';
import 'download_filter_provider.dart';
import 'download_list_provider.dart';
import 'download_queue_provider.dart';
import 'torrent_provider.dart';

/// Coordinator bridging sub-providers and forwarding state changes to maintain
/// backward compatibility across existing UI listeners.
class DownloadCoordinator extends ChangeNotifier {
  final DownloadListProvider listProvider;
  final DownloadQueueProvider queueProvider;
  final DownloadFilterProvider filterProvider;
  final TorrentProvider torrentProvider;

  DownloadCoordinator({
    required this.listProvider,
    required this.queueProvider,
    required this.filterProvider,
    required this.torrentProvider,
  }) {
    listProvider.addListener(notifyListeners);
    queueProvider.addListener(notifyListeners);
    filterProvider.addListener(notifyListeners);
    torrentProvider.addListener(notifyListeners);
  }

  List<DownloadTask> get tasks => listProvider.tasks;
  List<DownloadTask> get filteredTasks => filterProvider.filteredTasks;
  int get downloadingTasksCount => listProvider.tasks
      .where((t) => t.status == DownloadStatus.downloading)
      .length;

  int get activeOrSeedingCount => listProvider.tasks
      .where((t) =>
          t.status == DownloadStatus.downloading ||
          (t.status == DownloadStatus.completed &&
              t.isTorrent &&
              t.seedingEnabled))
      .length;

  DownloadTask? findTask(String id) => listProvider.findTask(id);

  Future<void> pauseTask(String id) => queueProvider.pauseTask(id);
  Future<void> resumeTask(String id) => queueProvider.resumeTask(id);
  Future<void> deleteTask(String id) => listProvider.deleteTask(id);

  @override
  void dispose() {
    listProvider.removeListener(notifyListeners);
    queueProvider.removeListener(notifyListeners);
    filterProvider.removeListener(notifyListeners);
    torrentProvider.removeListener(notifyListeners);
    super.dispose();
  }
}
