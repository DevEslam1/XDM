import 'dart:io';

import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockHost implements DownloadOrchestratorHost {
  _MockHost(this.task);

  DownloadTask task;
  final List<DownloadTask> cleanedUpTasks = [];

  @override
  DownloadTask? findTaskById(String id) => task.id == id ? task : null;

  @override
  Future<void> setTaskState(DownloadTask updated) async {
    task = updated;
  }

  @override
  Future<void> cleanupPartFiles(DownloadTask t, {bool preserveParts = false}) async {
    cleanedUpTasks.add(t);
  }

  @override
  bool get enableBackgroundTimers => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dmx_http_fixes_test_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('audio state check uses task-scoped .<taskId>.dmxstate on resume validation', () async {
    const taskId = 'task-yt-audio';
    const total = 2 * 1024 * 1024;
    final tempPath = '${tempDir.path}/video.mp4.dmxpart';
    final audioPath = '$tempPath.audio';

    await File(tempPath).writeAsBytes(List<int>.filled(total, 0), flush: true);
    await File(audioPath).writeAsBytes(List<int>.filled(total ~/ 2, 0), flush: true);

    // Save video state
    await StateStore.save(
      tempPath,
      TransferState(totalSize: total, threadCount: 1, chunks: [
        ChunkState(start: 0, end: total - 1, downloaded: total),
      ]),
      durable: true,
      taskId: taskId,
    );

    // Save task-scoped audio state
    await StateStore.save(
      audioPath,
      TransferState(totalSize: total, threadCount: 1, chunks: [
        ChunkState(start: 0, end: total - 1, downloaded: total ~/ 2),
      ]),
      durable: true,
      taskId: taskId,
    );

    final task = DownloadTask(
      id: taskId,
      fileName: 'video.mp4',
      url: 'https://example.com/video',
      mergedAudioUrl: 'https://example.com/audio',
      fileSize: total,
      downloadedBytes: total,
      audioSize: total,
      audioDownloadedBytes: total ~/ 2,
      audioProgress: 0.5,
      category: 'Video',
      status: DownloadStatus.paused,
      savePath: tempDir.path,
      localFilePath: '${tempDir.path}/video.mp4',
      tempFilePath: tempPath,
      threadCount: 1,
      chunks: const [1.0],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final host = _MockHost(task);
    final orchestrator = DownloadOrchestrator(host);

    final validated = await orchestrator.validateResumeState(task);

    // Audio progress must NOT be reset to 0.0 because the scoped state file was found!
    expect(validated.audioProgress, greaterThan(0.0));
    expect(validated.audioDownloadedBytes, equals(total ~/ 2));
  });

  test('cleanupTempFiles with preserveParts: true preserves temp file and StateStore state', () async {
    const taskId = 'task-preserve-test';
    final tempPath = '${tempDir.path}/large_file.bin.dmxpart';

    final tempFile = File(tempPath);
    await tempFile.writeAsBytes(List<int>.filled(1024 * 1024, 0), flush: true);

    await StateStore.save(
      tempPath,
      TransferState(totalSize: 10 * 1024 * 1024, threadCount: 2, chunks: [
        ChunkState(start: 0, end: 5 * 1024 * 1024 - 1, downloaded: 1024 * 1024),
        ChunkState(start: 5 * 1024 * 1024, end: 10 * 1024 * 1024 - 1, downloaded: 0),
      ]),
      durable: true,
      taskId: taskId,
    );

    final task = DownloadTask(
      id: taskId,
      fileName: 'large_file.bin',
      url: 'https://example.com/large_file.bin',
      fileSize: 10 * 1024 * 1024,
      downloadedBytes: 1024 * 1024,
      category: 'Other',
      status: DownloadStatus.failed,
      savePath: tempDir.path,
      localFilePath: '${tempDir.path}/large_file.bin',
      tempFilePath: tempPath,
      threadCount: 2,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final host = _MockHost(task);
    final orchestrator = DownloadOrchestrator(host);

    // Call cleanupTempFiles with preserveParts: true (as done for expired links / retries)
    await orchestrator.cleanupTempFiles(task, preserveParts: true);

    expect(await tempFile.exists(), isTrue, reason: 'Temp file must survive cleanup');
    final scopedStateFile = File(StateStore.pathFor(tempPath, taskId: taskId));
    expect(await scopedStateFile.exists(), isTrue, reason: 'Scoped StateStore state file must survive cleanup');
  });

  test('cleanupTempFiles with preserveParts: false deletes both legacy and scoped state files', () async {
    const taskId = 'task-full-cleanup-test';
    final tempPath = '${tempDir.path}/discard_file.bin.dmxpart';

    final tempFile = File(tempPath);
    await tempFile.writeAsBytes(List<int>.filled(1024, 0), flush: true);

    await StateStore.save(
      tempPath,
      TransferState(totalSize: 1024, threadCount: 1, chunks: [
        ChunkState(start: 0, end: 1023, downloaded: 1024),
      ]),
      durable: true,
      taskId: taskId,
    );

    final scopedStateFile = File(StateStore.pathFor(tempPath, taskId: taskId));
    expect(await scopedStateFile.exists(), isTrue);

    final task = DownloadTask(
      id: taskId,
      fileName: 'discard_file.bin',
      url: 'https://example.com/discard.bin',
      fileSize: 1024,
      downloadedBytes: 1024,
      category: 'Other',
      status: DownloadStatus.failed,
      savePath: tempDir.path,
      localFilePath: '${tempDir.path}/discard_file.bin',
      tempFilePath: tempPath,
      threadCount: 1,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final host = _MockHost(task);
    final orchestrator = DownloadOrchestrator(host);

    await orchestrator.cleanupTempFiles(task, preserveParts: false);

    expect(await tempFile.exists(), isFalse);
    expect(await scopedStateFile.exists(), isFalse);
  });
}
