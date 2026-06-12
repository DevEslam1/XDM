import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DownloadTask serializes and deserializes persisted fields', () {
    final now = DateTime(2026, 6, 5, 12);
    final completed = now.add(const Duration(minutes: 1));
    final task = DownloadTask(
      id: '1',
      fileName: 'sample.zip',
      url: 'https://example.com/sample.zip',
      fileSize: 2048,
      downloadedBytes: 1024,
      speed: 512,
      eta: 2,
      category: 'Archive',
      status: DownloadStatus.downloading,
      savePath: 'D:/Downloads',
      localFilePath: 'D:/Downloads/sample.zip',
      tempFilePath: 'D:/Downloads/sample.zip.dmxpart',
      errorMessage: 'Previous error',
      threadCount: 4,
      chunks: const [0.2, 0.3, 0.4, 0.5],
      createdAt: now,
      updatedAt: now,
      completedAt: completed,
      supportsResume: true,
      downloadPageUrl: 'https://example.com/download-page',
    );

    final restored = DownloadTask.fromMap(task.toMap());

    expect(restored.id, task.id);
    expect(restored.status, DownloadStatus.downloading);
    expect(restored.localFilePath, task.localFilePath);
    expect(restored.tempFilePath, task.tempFilePath);
    expect(restored.threadCount, 4);
    expect(restored.chunks, task.chunks);
    expect(restored.supportsResume, isTrue);
    expect(restored.completedAt, completed);
    expect(restored.downloadPageUrl, 'https://example.com/download-page');
  });
}
