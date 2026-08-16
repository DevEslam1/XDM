import '../models/pause_reason.dart';
import '../provider/download_queue_provider.dart';

/// Clean Architecture Use Case for pausing download tasks.
class PauseDownloadUseCase {
  final DownloadQueueProvider _queueProvider;

  const PauseDownloadUseCase(this._queueProvider);

  Future<void> call(String taskId,
      {PauseReason reason = PauseReason.userRequested}) async {
    await _queueProvider.pauseTask(taskId, reason: reason);
  }
}
