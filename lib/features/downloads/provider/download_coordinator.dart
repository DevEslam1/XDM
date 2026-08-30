import 'package:flutter/foundation.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
// DownloadListProvider expects the data-layer [TaskRepository] abstraction,
// not the provider-layer repository of the same name.
import '../data/task_repository.dart';
import 'download_list_provider.dart';
import 'download_queue_provider.dart';
import 'torrent_provider.dart';
import 'download_filter_provider.dart';

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
    required DownloadListProvider listProvider,
    required DownloadQueueProvider queueProvider,
    required TorrentProvider torrentProvider,
    required DownloadFilterProvider filterProvider,
  })  : listProvider = listProvider,
        queueProvider = queueProvider,
        torrentProvider = torrentProvider,
        filterProvider = filterProvider {
    this.listProvider.addListener(notifyListeners);
    this.queueProvider.addListener(notifyListeners);
    this.torrentProvider.addListener(notifyListeners);
    this.filterProvider.addListener(notifyListeners);
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
