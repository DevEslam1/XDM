import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';
import 'package:dmx/features/downloads/provider/task_queue_manager.dart';

class MockDownloadOrchestrator extends Mock implements DownloadOrchestrator {}

DownloadTask createTestTask({
  String id = 'task-1',
  String fileName = 'test.zip',
  String url = 'https://example.com/test.zip',
  int fileSize = 1000,
  int downloadedBytes = 0,
  String category = 'Other',
  DownloadStatus status = DownloadStatus.queued,
  String savePath = '/downloads/test.zip',
  String localFilePath = '/downloads/test.zip',
  String tempFilePath = '/downloads/test.zip.dmxpart',
  int threadCount = 1,
  List<double> chunks = const [0.0],
  DateTime? createdAt,
  DateTime? updatedAt,
  int queueOrder = 0,
  double speed = 0.0,
}) {
  final now = DateTime.now();
  return DownloadTask(
    id: id,
    fileName: fileName,
    url: url,
    fileSize: fileSize,
    downloadedBytes: downloadedBytes,
    category: category,
    status: status,
    savePath: savePath,
    localFilePath: localFilePath,
    tempFilePath: tempFilePath,
    threadCount: threadCount,
    chunks: chunks,
    createdAt: createdAt ?? now,
    updatedAt: updatedAt ?? now,
    queueOrder: queueOrder,
    speed: speed,
  );
}

void main() {
  group('TaskQueueManager', () {
    late MockDownloadOrchestrator orchestrator;
    late List<DownloadTask> tasks;
    late TaskQueueManager queueManager;
    var pumpCalled = false;

    setUp(() {
      orchestrator = MockDownloadOrchestrator();
      pumpCalled = false;
      tasks = [
        createTestTask(id: 'task-1', fileName: '1', url: 'https://example.com/1', queueOrder: 0),
        createTestTask(id: 'task-2', fileName: '2', url: 'https://example.com/2', queueOrder: 1),
        createTestTask(id: 'task-3', fileName: '3', url: 'https://example.com/3', queueOrder: 2),
      ];

      queueManager = TaskQueueManager(
        orchestrator: orchestrator,
        pumpQueueCallback: () => pumpCalled = true,
        tasksGetter: () => tasks,
      );
    });

    test('reorderTasks moves task to target index and recalculates queueOrder', () {
      queueManager.reorderTasks(2, 0);

      expect(tasks[0].id, 'task-3');
      expect(tasks[0].queueOrder, 0);
      expect(tasks[1].id, 'task-1');
      expect(tasks[1].queueOrder, 1);
      expect(tasks[2].id, 'task-2');
      expect(tasks[2].queueOrder, 2);
      expect(pumpCalled, true);
    });

    test('reorderTasks ignores out-of-bounds indices', () {
      queueManager.reorderTasks(-1, 5);
      expect(tasks[0].id, 'task-1');
      expect(pumpCalled, false);
    });

    test('boostPriority moves task to head of the queue', () async {
      await queueManager.boostPriority('task-2');

      expect(tasks[0].id, 'task-2');
      expect(tasks[0].queueOrder, 0);
      expect(tasks[1].id, 'task-1');
      expect(pumpCalled, true);
    });

    test('boostPriority on already-first task is a no-op', () async {
      await queueManager.boostPriority('task-1');
      expect(tasks[0].id, 'task-1');
      expect(pumpCalled, false);
    });

    test('delegates isTaskPendingStart and pendingStartCount to orchestrator', () {
      when(() => orchestrator.pendingStartCount).thenReturn(2);
      when(() => orchestrator.isTaskPendingStart('task-1')).thenReturn(true);

      expect(queueManager.pendingStartCount, 2);
      expect(queueManager.isTaskPendingStart('task-1'), true);
    });
  });
}
