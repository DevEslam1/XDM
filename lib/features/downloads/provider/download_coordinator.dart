import 'package:flutter/foundation.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'download_list_provider.dart';
import 'download_queue_provider.dart';
import 'torrent_provider.dart';
import 'download_filter_provider.dart';

class DownloadCoordinator extends ChangeNotifier {
  DownloadCoordinator({
    DownloadListProvider? listProvider,
    DownloadQueueProvider? queueProvider,
    TorrentProvider? torrentProvider,
    DownloadFilterProvider? filterProvider,
  })  : listProvider = listProvider ?? DownloadListProvider(),
        queueProvider = queueProvider ?? DownloadQueueProvider(),
        torrentProvider = torrentProvider ?? TorrentProvider(),
        filterProvider = filterProvider ?? DownloadFilterProvider() {
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
