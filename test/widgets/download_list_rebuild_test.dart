import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';

void main() {
  testWidgets(
      'DownloadTask == compares by id only, while provider revision changes',
      (tester) async {
    final task1 = DownloadTask(
      id: 'task-1',
      url: 'https://example.com/file1.zip',
      fileName: 'file1.zip',
      fileSize: 1000,
      downloadedBytes: 100,
      category: 'Other',
      status: DownloadStatus.downloading,
      savePath: '/downloads',
      localFilePath: '/downloads/file1.zip',
      tempFilePath: '/downloads/file1.zip.tmp',
      threadCount: 4,
      chunks: const [],
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

    final updatedTask1 = task1.copyWith(downloadedBytes: 500);

    expect(task1 == updatedTask1, isTrue,
        reason: 'DownloadTask == checks id only');
  });
}
