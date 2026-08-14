import '../provider/download_queue_provider.dart';

/// Clean Architecture Use Case for pausing download tasks.
class PauseDownloadUseCase {
  final DownloadQueueProvider _queueProvider;

  const PauseDownloadUseCase(this._queueProvider);

  Future<void> call(String taskId) async {
    await _queueProvider.pauseTask(taskId);
  }
}
