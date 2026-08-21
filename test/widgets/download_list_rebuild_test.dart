import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'DownloadTask id matches while value equality detects progress changes',
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

    final sameTask1 = task1.copyWith();
    final updatedTask1 = task1.copyWith(downloadedBytes: 500);

    expect(task1.id == updatedTask1.id, isTrue);
    expect(task1 == sameTask1, isTrue);
    expect(task1 == updatedTask1, isFalse,
        reason: 'DownloadTask value equality detects progress changes');
  });
}
