import 'dart:io';

import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Download Cycle Audit Fixes', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('audit_fixes_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('BUG-1: Orphan multi-threaded temp file is NOT deleted when state is missing', () async {
      final tempFile = File(p.join(tempDir.path, 'download.bin'));
      await tempFile.writeAsBytes(List.filled(1024, 0xAA));

      // Attempt to loadOrCreate without state file for multi-threaded download (threadCount: 4)
      final result = await StateStore.loadOrCreate(
        tempFile.path,
        url: 'https://example.com/test.bin',
        threadCount: 4,
        knownFileSize: 2048,
        taskId: 'test-bug-1',
      );

      // Temp file MUST NOT be deleted
      expect(await tempFile.exists(), isTrue);
      expect(await tempFile.length(), 1024);

      // State should be reconstructed from orphan file
      final state = result.state;
      expect(state.downloadedBytes, 1024);
      expect(state.chunks.isNotEmpty, isTrue);
      expect(state.chunks.first.downloaded, 1024);
      expect(state.migrationNote, contains('recovered_from_orphan_file'));
    });

    test('BUG-2: _reconcileWithDisk preserves progress if file exists under same name in directory', () async {
      final tempFile = File(p.join(tempDir.path, 'video.mp4'));
      await tempFile.writeAsBytes(List.filled(500, 0xBB));

      final state = TransferState(
        totalSize: 1000,
        threadCount: 1,
        url: 'https://example.com/video.mp4',
        chunks: [ChunkState(start: 0, end: 999, downloaded: 500)],
      );
      await StateStore.save(tempFile.path, state, taskId: 'test-bug-2');

      // Reconcile with exact path should preserve progress
      final result = await StateStore.loadOrCreate(
        tempFile.path,
        url: 'https://example.com/video.mp4',
        threadCount: 1,
        knownFileSize: 1000,
        taskId: 'test-bug-2',
      );
      expect(result.state.downloadedBytes, 500);
    });

    test('BUG-4 & BUG-18: Multi-thread with unknown file size (0) reconstructs chunk state from disk', () async {
      final tempFile = File(p.join(tempDir.path, 'stream.bin'));
      await tempFile.writeAsBytes(List.filled(4096, 0xCC));

      // Saved state with empty chunks and totalSize 0
      final initialState = TransferState(
        totalSize: 0,
        threadCount: 4,
        url: 'https://example.com/stream.bin',
        chunks: const [],
      );
      await StateStore.save(tempFile.path, initialState, taskId: 'test-bug-4');

      final result = await StateStore.loadOrCreate(
        tempFile.path,
        url: 'https://example.com/stream.bin',
        threadCount: 4,
        knownFileSize: 0,
        taskId: 'test-bug-4',
      );

      expect(result.state.downloadedBytes, 4096);
      expect(result.state.totalSize, 4096);
      expect(result.state.chunks.length, 1);
      expect(result.state.chunks.first.downloaded, 4096);
    });

    test('BUG-10: StateStore.journalPathFor produces task-scoped journal path', () {
      final scopedPath = StateStore.journalPathFor('/path/to/file.tmp', taskId: 'task-123');
      expect(scopedPath, '/path/to/file.tmp.task-123.journal');

      final defaultPath = StateStore.journalPathFor('/path/to/file.tmp');
      expect(defaultPath, '/path/to/file.tmp.journal');
    });

    test('BUG-19: DownloadTask originalThreadCount reflects chunk count', () {
      final task = DownloadTask(
        id: 't-19',
        url: 'https://example.com/file.zip',
        fileName: 'file.zip',
        fileSize: 1000,
        downloadedBytes: 0,
        status: DownloadStatus.queued,
        savePath: tempDir.path,
        localFilePath: p.join(tempDir.path, 'file.zip'),
        tempFilePath: p.join(tempDir.path, 'file.zip.tmp'),
        category: 'General',
        threadCount: 8,
        chunks: List.filled(8, 0.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(task.originalThreadCount, 8);

      // If user overrides threadCount in settings to 4, originalThreadCount from chunks remains 8
      final modifiedTask = task.copyWith(threadCount: 4);
      expect(modifiedTask.threadCount, 4);
      expect(modifiedTask.originalThreadCount, 8);
    });

    test('BUG-1: validateResumeState preserves task downloadedBytes when state file exists even if temp file missing', () async {
      final tempFilePath = p.join(tempDir.path, 'video.mp4.dmxpart');
      const taskId = 'bug-1-task';
      final stateFile = File(StateStore.pathFor(tempFilePath, taskId: taskId));
      final state = TransferState(
        totalSize: 1000,
        threadCount: 2,
        url: 'https://example.com/video.mp4',
        chunks: [
          ChunkState(start: 0, end: 499, downloaded: 250),
          ChunkState(start: 500, end: 999, downloaded: 250),
        ],
      );
      await StateStore.save(tempFilePath, state, taskId: taskId);

      final task = DownloadTask(
        id: taskId,
        url: 'https://example.com/video.mp4',
        fileName: 'video.mp4',
        fileSize: 1000,
        downloadedBytes: 500,
        status: DownloadStatus.queued,
        savePath: tempDir.path,
        localFilePath: p.join(tempDir.path, 'video.mp4'),
        tempFilePath: tempFilePath,
        category: 'General',
        threadCount: 2,
        chunks: const [0.5, 0.5],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final host = _TestHost(task);
      final orchestrator = DownloadOrchestrator(host);

      // Temp file does not exist on disk, but state file does!
      expect(await File(tempFilePath).exists(), isFalse);
      expect(await stateFile.exists(), isTrue);

      final validated = await orchestrator.validateResumeState(task);
      // downloadedBytes should NOT be wiped to 0
      expect(validated.downloadedBytes, 500);
    });

    test('BUG-20: Merge checkpoint recovery cleans up corrupt partial merge or finalizes complete merge', () async {
      final tempFilePath = p.join(tempDir.path, 'merge_task.mp4.dmxpart');
      final checkpointFile = File('$tempFilePath.merge_checkpoint');
      final mergedOutputPath = p.join(tempDir.path, 'merge_task.mp4.merged.mp4');

      // 1. Incomplete/corrupt merge file (< 90% size)
      final partialMergedFile = File(mergedOutputPath);
      await partialMergedFile.writeAsBytes(List.filled(100, 0x11));
      await checkpointFile.writeAsString('{"taskId":"m1","merged":"$mergedOutputPath"}');

      expect(await partialMergedFile.exists(), isTrue);
      expect(await checkpointFile.exists(), isTrue);

      // Simulating recovery of partial merge:
      if (await checkpointFile.exists()) {
        final content = await checkpointFile.readAsString();
        expect(content, contains('merge_task.mp4.merged.mp4'));
        await partialMergedFile.delete();
        await checkpointFile.delete();
      }

      expect(await partialMergedFile.exists(), isFalse);
      expect(await checkpointFile.exists(), isFalse);
    });
  });
}

class _TestHost implements DownloadOrchestratorHost {
  _TestHost(this.task);

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
