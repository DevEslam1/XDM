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
///
/// ─────────────────────────────────────────────────────────────────────────────
/// ⚠️  NOT INSTANTIATED — This class is never registered in the DI container
///     and is never called from any UI or service layer.
/// ─────────────────────────────────────────────────────────────────────────────
///
/// ## Why this is orphaned
///
/// All actual download lifecycle logic (pause/resume/retry/start) is handled
/// directly by [DownloadProvider] in `download_provider.dart` (~6,600 lines).
/// The UI layer calls `context.read<DownloadProvider>().pauseTask(...)` etc.
/// directly; none of the usecase/coordinator path is involved at runtime.
///
/// ## What would be required to "activate" this layer
///
/// 1. Register [DownloadCoordinator] in the DI container (`injection.dart`)
///    and replace every `context.read<DownloadProvider>()` callsite in the UI
///    with `context.read<DownloadCoordinator>()`.
/// 2. Wire [PauseDownloadUseCase] to pass the correct [PauseReason] so
///    `task.pauseReason` is set (currently it only passes `userRequested`).
/// 3. Add `startTask` and `retryTask` usecases (they don't exist in this layer).
/// 4. Replace [RetryDownloadUseCase] with a real implementation that matches
///    `DownloadProvider._retryTaskInternal` — YouTube URL refresh, failure
///    classification, merge-only retry, CycleState/pauseReason clearing, etc.
///
/// ## What to do instead
///
/// Do NOT add logic here. Extend [DownloadProvider] and its orchestrator.
/// If a full Clean Architecture refactor is planned, start with a working
/// integration test suite first, then migrate one operation at a time.
///
/// Task 1.3: Enforce Clean Architecture Boundaries — deferred pending refactor.
@Deprecated(
  'DownloadCoordinator is never instantiated. '
  'All runtime logic lives in DownloadProvider. '
  'See the class docstring for a migration checklist.',
)
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

  Future<void> pauseTask(String id,
          {PauseReason reason = PauseReason.userRequested}) =>
      _pauseUseCase(id, reason: reason);
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
