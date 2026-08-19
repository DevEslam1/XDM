import 'package:dmx/features/downloads/data/task_repository.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_list_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadListProvider Granular Notifiers (Sprint 3)', () {
    test('progressRatioFor and speedFor update when updateTask is called',
        () async {
      final repo = InMemoryTaskRepository();
      final provider = DownloadListProvider(repo);

      final task = DownloadTask(
        id: 'task-10',
        fileName: 'video.mp4',
        url: 'https://example.com/video.mp4',
        fileSize: 1000,
        downloadedBytes: 100,
        speed: 50.0,
        category: 'Video',
        status: DownloadStatus.downloading,
        savePath: '/video.mp4',
        localFilePath: '/video.mp4',
        tempFilePath: '/video.mp4.tmp',
        threadCount: 2,
        chunks: [0.1],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await provider.addTask(task);

      final progressNotifier = provider.progressRatioFor('task-10');
      final speedNotifier = provider.speedFor('task-10');

      expect(progressNotifier.value, equals(0.1));
      expect(speedNotifier.value, equals(50.0));

      final updatedTask = task.copyWith(
        downloadedBytes: 500,
        speed: 250.0,
      );

      await provider.updateTask(updatedTask);

      expect(progressNotifier.value, equals(0.5));
      expect(speedNotifier.value, equals(250.0));

      provider.dispose();
    });
  });
}
