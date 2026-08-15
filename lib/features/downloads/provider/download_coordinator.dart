import 'package:flutter/foundation.dart';

import '../models/download_task.dart';
import '../usecases/delete_download_usecase.dart';
import '../usecases/pause_download_usecase.dart';
import '../usecases/resume_download_usecase.dart';
import 'download_filter_provider.dart';
import 'download_list_provider.dart';
import 'download_queue_provider.dart';
import 'torrent_provider.dart';

/// Coordinator bridging sub-providers and enforcing Clean Architecture boundaries
/// by delegating actions to specialized UseCases.
/// Task 1.3: Enforce Clean Architecture Boundaries.
class DownloadCoordinator extends ChangeNotifier {
  final DownloadListProvider listProvider;
  final DownloadQueueProvider queueProvider;
  final DownloadFilterProvider filterProvider;
  final TorrentProvider torrentProvider;

  // UseCases
  final PauseDownloadUseCase _pauseUseCase;
  final ResumeDownloadUseCase _resumeUseCase;
  final DeleteDownloadUseCase _deleteUseCase;

  DownloadCoordinator({
    required this.listProvider,
    required this.queueProvider,
    required this.filterProvider,
    required this.torrentProvider,
    required PauseDownloadUseCase pauseUseCase,
    required ResumeDownloadUseCase resumeUseCase,
    required DeleteDownloadUseCase deleteUseCase,
  })  : _pauseUseCase = pauseUseCase,
        _resumeUseCase = resumeUseCase,
        _deleteUseCase = deleteUseCase {
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

  Future<void> pauseTask(String id) => _pauseUseCase(id);
  Future<void> resumeTask(String id) => _resumeUseCase(id);
  Future<void> deleteTask(String id) => _deleteUseCase(id);

  @override
  void dispose() {
    listProvider.removeListener(notifyListeners);
    queueProvider.removeListener(notifyListeners);
    filterProvider.removeListener(notifyListeners);
    torrentProvider.removeListener(notifyListeners);
    super.dispose();
  }
}
