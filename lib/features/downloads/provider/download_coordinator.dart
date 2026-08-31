import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter/foundation.dart';

// DownloadListProvider expects the data-layer [TaskRepository] abstraction,
// not the provider-layer repository of the same name.
import '../data/task_repository.dart';
import 'download_filter_provider.dart';
import 'download_list_provider.dart';
import 'download_queue_provider.dart';
import 'torrent_provider.dart';

class DownloadCoordinator extends ChangeNotifier {
  factory DownloadCoordinator({
    DownloadListProvider? listProvider,
    DownloadQueueProvider? queueProvider,
    TorrentProvider? torrentProvider,
    DownloadFilterProvider? filterProvider,
  }) {
    final effectiveList =
        listProvider ?? DownloadListProvider(InMemoryTaskRepository());
    return DownloadCoordinator._internal(
      listProvider: effectiveList,
      queueProvider: queueProvider ?? DownloadQueueProvider(),
      torrentProvider: torrentProvider ?? TorrentProvider(),
      filterProvider: filterProvider ?? DownloadFilterProvider(effectiveList),
    );
  }

  DownloadCoordinator._internal({
    required this.listProvider,
    required this.queueProvider,
    required this.torrentProvider,
    required this.filterProvider,
  }) {
    listProvider.addListener(notifyListeners);
    queueProvider.addListener(notifyListeners);
    torrentProvider.addListener(notifyListeners);
    filterProvider.addListener(notifyListeners);
  }

  final DownloadListProvider listProvider;
  final DownloadQueueProvider queueProvider;
  final TorrentProvider torrentProvider;
  final DownloadFilterProvider filterProvider;

  List<DownloadTask> get filteredTasks =>
      filterProvider.applyFilter(listProvider.tasks);

  @override
  void dispose() {
    listProvider.removeListener(notifyListeners);
    queueProvider.removeListener(notifyListeners);
    torrentProvider.removeListener(notifyListeners);
    filterProvider.removeListener(notifyListeners);
    super.dispose();
  }
}
