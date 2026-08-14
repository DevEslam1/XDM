import '../provider/download_queue_provider.dart';

/// Clean Architecture Use Case for resuming download tasks.
class ResumeDownloadUseCase {
  final DownloadQueueProvider _queueProvider;

  const ResumeDownloadUseCase(this._queueProvider);

  Future<void> call(String taskId) async {
    await _queueProvider.resumeTask(taskId);
  }
}
