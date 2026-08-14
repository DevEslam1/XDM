import '../models/download_task.dart';
import '../provider/download_list_provider.dart';

/// Clean Architecture Use Case for cancelling download tasks.
class CancelDownloadUseCase {
  final DownloadListProvider _listProvider;

  const CancelDownloadUseCase(this._listProvider);

  Future<void> call(String taskId) async {
    final task = _listProvider.findTask(taskId);
    if (task != null) {
      await _listProvider.updateTask(
        task.copyWith(
          status: DownloadStatus.failed,
          errorMessage: 'Cancelled by user',
        ),
      );
    }
  }
}
