import '../models/download_task.dart';
import '../provider/download_list_provider.dart';
import '../provider/download_queue_provider.dart';

/// Clean Architecture Use Case for retrying failed download tasks.
class RetryDownloadUseCase {
  final DownloadListProvider _listProvider;
  final DownloadQueueProvider _queueProvider;

  const RetryDownloadUseCase(this._listProvider, this._queueProvider);

  Future<void> call(String taskId) async {
    final task = _listProvider.findTask(taskId);
    if (task != null) {
      await _listProvider.updateTask(
        task.copyWith(
          status: DownloadStatus.queued,
          clearError: true,
        ),
      );
      _queueProvider.pumpQueue();
    }
  }
}
