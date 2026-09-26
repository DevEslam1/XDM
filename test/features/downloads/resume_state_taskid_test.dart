import 'dart:io';

import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal host exposing just what validateResumeState touches.
class _TaskHost implements DownloadOrchestratorHost {
  _TaskHost(this.task);

  DownloadTask task;

  @override
  DownloadTask? findTaskById(String id) => task.id == id ? task : null;

  @override
  Future<void> setTaskState(DownloadTask updated) async {
    task = updated;
  }

  @override
  bool get enableBackgroundTimers => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// F28 regression: the engine writes resume state to the TASK-SCOPED sidecar
/// (`<temp>.<taskId>.dmxstate`). `validateResumeState` previously loaded without
/// the taskId, read the legacy un-suffixed file (absent), saw 0 progress and
/// wiped the task — so a pause/resume re-downloaded from the start.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('f28_resume_state_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('resume recovers progress from the task-scoped state file', () async {
    const taskId = 'task-abc';
    const total = 4 * 1024 * 1024;
    final tempPath = '${tempDir.path}/movie.mp4.dmxpart';
    final localPath = '${tempDir.path}/movie.mp4';

    // Simulate a partial .dmxpart on disk.
    await File(tempPath).writeAsBytes(
      List<int>.filled(total ~/ 2, 0),
      flush: true,
    );

    // The engine persists to the task-scoped sidecar.
    await StateStore.save(
      tempPath,
      TransferState(
        totalSize: total,
        threadCount: 2,
        chunks: [
          ChunkState(start: 0, end: total ~/ 2 - 1, downloaded: total ~/ 4),
          ChunkState(
              start: total ~/ 2, end: total - 1, downloaded: total ~/ 4),
        ],
      ),
      durable: true,
      taskId: taskId,
    );

    final task = DownloadTask(
      id: taskId,
      fileName: 'movie.mp4',
      url: 'https://example.com/movie.mp4',
      fileSize: total,
      downloadedBytes: total ~/ 2,
      category: 'Video',
      status: DownloadStatus.paused,
      savePath: tempDir.path,
      localFilePath: localPath,
      tempFilePath: tempPath,
      threadCount: 2,
      chunks: const [0.5, 0.5],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final host = _TaskHost(task);
    final orchestrator = DownloadOrchestrator(host);

    final validated = await orchestrator.validateResumeState(task);

    expect(
      validated.downloadedBytes,
      equals(total ~/ 2),
      reason: 'resume must recover the engine-saved byte count, not reset to 0',
    );
    expect(validated.chunks.length, equals(2));
    expect(
      validated.chunks.reduce((a, b) => a + b),
      closeTo(1.0, 0.01),
    );
  });

  test('legacy (un-suffixed) state is still honored as a fallback', () async {
    const taskId = 'task-legacy';
    const total = 1024 * 1024;
    final tempPath = '${tempDir.path}/legacy.bin.dmxpart';

    await File(tempPath).writeAsBytes(
      List<int>.filled(2048, 0),
      flush: true,
    );

    // Only the legacy file exists (no taskId suffix).
    await StateStore.save(
      tempPath,
      TransferState(
        totalSize: total,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: total - 1, downloaded: 2048)],
      ),
      durable: true,
    );

    final task = DownloadTask(
      id: taskId,
      fileName: 'legacy.bin',
      url: 'https://example.com/legacy.bin',
      fileSize: total,
      downloadedBytes: 2048,
      category: 'Other',
      status: DownloadStatus.paused,
      savePath: tempDir.path,
      localFilePath: '${tempDir.path}/legacy.bin',
      tempFilePath: tempPath,
      threadCount: 1,
      chunks: const [0.002],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final orchestrator = DownloadOrchestrator(_TaskHost(task));
    final validated = await orchestrator.validateResumeState(task);

    expect(validated.downloadedBytes, equals(2048));
  });
}
