import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/task_state_service.dart';

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
  group('TaskStateService', () {
    late TaskStateService service;

    setUp(() {
      service = TaskStateService();
    });

    tearDown(() {
      service.dispose();
    });

    test('starts empty and adds task correctly', () {
      expect(service.isEmpty, true);
      expect(service.count, 0);

      final task = createTestTask(
        id: 'task-1',
        url: 'https://example.com/1.zip',
        fileName: '1.zip',
      );

      service.add(task);
      expect(service.isEmpty, false);
      expect(service.count, 1);
      expect(service.getById('task-1'), isNotNull);
      expect(service.getById('task-1')!.fileName, '1.zip');
    });

    test('update modifies existing task in place', () {
      final task = createTestTask(
        id: 'task-update',
        url: 'https://example.com/update.zip',
        fileName: 'update.zip',
      );
      service.add(task);

      final updated = task.copyWith(status: DownloadStatus.downloading, speed: 500);
      final ok = service.update(updated);

      expect(ok, true);
      expect(service.getById('task-update')!.status, DownloadStatus.downloading);
      expect(service.getById('task-update')!.speed, 500);
    });

    test('remove deletes task and frees its lock', () {
      final task = createTestTask(
        id: 'task-remove',
        url: 'https://example.com/remove.zip',
        fileName: 'remove.zip',
        status: DownloadStatus.completed,
      );
      service.add(task);
      expect(service.count, 1);

      final removed = service.remove('task-remove');
      expect(removed, true);
      expect(service.count, 0);
      expect(service.getById('task-remove'), isNull);
    });

    test('findByStatus filters tasks by download status', () {
      final t1 = createTestTask(
        id: 't1',
        url: 'https://example.com/t1',
        fileName: 't1',
        status: DownloadStatus.downloading,
      );
      final t2 = createTestTask(
        id: 't2',
        url: 'https://example.com/t2',
        fileName: 't2',
        status: DownloadStatus.completed,
      );
      final t3 = createTestTask(
        id: 't3',
        url: 'https://example.com/t3',
        fileName: 't3',
        status: DownloadStatus.downloading,
      );

      service.addAll([t1, t2, t3]);

      final downloading = service.findByStatus(DownloadStatus.downloading);
      final completed = service.findByStatus(DownloadStatus.completed);

      expect(downloading.length, 2);
      expect(completed.length, 1);
    });

    test('lockFor returns consistent Lock instance per task ID', () {
      final lock1 = service.lockFor('task-xyz');
      final lock2 = service.lockFor('task-xyz');
      final lock3 = service.lockFor('task-abc');

      expect(identical(lock1, lock2), true);
      expect(identical(lock1, lock3), false);
    });
  });
}
