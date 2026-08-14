import '../provider/download_list_provider.dart';

/// Clean Architecture Use Case for deleting download tasks.
class DeleteDownloadUseCase {
  final DownloadListProvider _listProvider;

  const DeleteDownloadUseCase(this._listProvider);

  Future<void> call(String taskId) async {
    await _listProvider.deleteTask(taskId);
  }
}
