import '../models/download_task.dart';
import '../provider/download_list_provider.dart';
import '../provider/download_queue_provider.dart';

/// Clean Architecture Use Case for adding and queueing a new download.
class StartDownloadUseCase {
  final DownloadListProvider _listProvider;
  final DownloadQueueProvider _queueProvider;

  const StartDownloadUseCase(this._listProvider, this._queueProvider);

  Future<void> call(DownloadTask task) async {
    await _listProvider.addTask(task);
    _queueProvider.addToQueue(task.id);
    _queueProvider.pumpQueue();
  }
}
