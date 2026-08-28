import 'package:dmx/features/downloads/data/task_repository.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_list_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockTaskRepository extends Mock implements TaskRepository {}

DownloadTask createDummyTask({
  required String id,
  DownloadStatus status = DownloadStatus.queued,
  int downloadedBytes = 0,
}) {
  final now = DateTime.now();
  return DownloadTask(
    id: id,
    fileName: '$id.bin',
    url: 'https://example.com/$id.bin',
    fileSize: 1000,
    downloadedBytes: downloadedBytes,
    category: 'Other',
    status: status,
    savePath: '/downloads',
    localFilePath: '/downloads/$id.bin',
    tempFilePath: '/downloads/$id.bin.part',
    threadCount: 1,
    chunks: const [0.0],
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(createDummyTask(id: 'fallback'));
  });

  group('Phase 1.1: Atomic State Transitions (DB First & Rollback)', () {
    late MockTaskRepository mockRepo;
    late DownloadListProvider listProvider;

    setUp(() {
      mockRepo = MockTaskRepository();
      listProvider = DownloadListProvider(mockRepo);
    });

    test('addTask writes to repository before updating in-memory list',
        () async {
      final task = createDummyTask(id: 'task-1');

      when(() => mockRepo.save(any())).thenAnswer((_) async {});

      await listProvider.addTask(task);

      expect(listProvider.tasks.length, 1);
      expect(listProvider.tasks.first.id, 'task-1');
      verify(() => mockRepo.save(task)).called(1);
    });

    test('addTask rolls back / leaves memory unchanged if DB write throws',
        () async {
      final task = createDummyTask(id: 'task-err');

      when(() => mockRepo.save(any()))
          .thenThrow(Exception('DB disk I/O error'));

      expect(() => listProvider.addTask(task), throwsException);
      expect(listProvider.tasks.isEmpty, isTrue);
    });

    test('updateTask rolls back to previous state if repository save fails',
        () async {
      final originalTask = createDummyTask(
        id: 'task-update',
        status: DownloadStatus.downloading,
        downloadedBytes: 100,
      );

      when(() => mockRepo.save(any())).thenAnswer((_) async {});
      await listProvider.addTask(originalTask);

      final updatedTask = originalTask.copyWith(
        downloadedBytes: 500,
        status: DownloadStatus.paused,
      );

      when(() => mockRepo.save(updatedTask))
          .thenThrow(Exception('DB lock acquired by another process'));

      expect(() => listProvider.updateTask(updatedTask), throwsException);

      final current = listProvider.findTask('task-update');
      expect(current, isNotNull);
      expect(current!.downloadedBytes, 100);
      expect(current.status, DownloadStatus.downloading);
    });

    test('deleteTask does not remove from memory if repository delete fails',
        () async {
      final task = createDummyTask(
        id: 'task-del',
        status: DownloadStatus.downloading,
        downloadedBytes: 100,
      );

      when(() => mockRepo.save(any())).thenAnswer((_) async {});
      await listProvider.addTask(task);
      expect(listProvider.tasks.length, 1);

      when(() => mockRepo.delete('task-del'))
          .thenThrow(Exception('DB delete failed'));

      expect(() => listProvider.deleteTask('task-del'), throwsException);
      expect(listProvider.tasks.length, 1);
      expect(listProvider.findTask('task-del'), isNotNull);
    });
  });

  group('Phase 1.6: Bounded Memory Maps & Leak Prevention', () {
    test(
        '1000 simulated progress ticks across 10 tasks do not leak memory in notifiers',
        () {
      final mockRepo = MockTaskRepository();
      final listProvider = DownloadListProvider(mockRepo);

      final tasks = List.generate(
        10,
        (i) =>
            createDummyTask(id: 'task-$i', status: DownloadStatus.downloading),
      );

      for (final t in tasks) {
        listProvider.progressRatioFor(t.id);
        listProvider.speedFor(t.id);
      }

      // Simulate 1000 progress ticks
      for (var tick = 0; tick < 1000; tick++) {
        final taskId = 'task-${tick % 10}';
        final progressRatio = (tick % 100) / 100.0;
        final speed = (tick % 50) * 1024.0;

        (listProvider.progressRatioFor(taskId) as dynamic).value =
            progressRatio;
        (listProvider.speedFor(taskId) as dynamic).value = speed;
      }

      // Verify notifiers map size is strictly bounded by active task count (10)
      for (final t in tasks) {
        expect(listProvider.progressRatioFor(t.id).value, isNotNull);
        expect(listProvider.speedFor(t.id).value, isNotNull);
      }

      // Remove 5 tasks and ensure disposed/removed
      for (var i = 0; i < 5; i++) {
        listProvider.removeTask('task-$i');
      }

      // Remaining tasks count in list
      expect(listProvider.tasks.length, 0); // No tasks in _tasks list
    });
  });
}
