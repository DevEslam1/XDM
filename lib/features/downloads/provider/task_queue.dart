import '../models/download_task.dart';
import 'download_queue_engine.dart';

/// Legacy facade forwarding to [DownloadQueueEngine].
class TaskQueue {
  final _engine = DownloadQueueEngine();

  List<DownloadTask> getQueuedTasks(List<DownloadTask> tasks) =>
      _engine.getQueuedTasks(tasks);

  List<DownloadTask> reorder(
    List<DownloadTask> tasks,
    int oldIndex,
    int newIndex,
  ) =>
      _engine.reorder(tasks, oldIndex, newIndex);
}
