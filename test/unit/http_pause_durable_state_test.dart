import 'dart:io';

import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HTTP Pause Durable State & DB Debounce Bypass', () {
    late Directory tempDir;
    late String tempFilePath;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('dmx_pause_test_');
      tempFilePath = '${tempDir.path}/test_file.bin.dmxdownload';
    });

    tearDown(() async {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test(
        'Saving state with durable: true flushes state and journal immediately',
        () async {
      // Create temp file on disk so reconciliation matches downloaded bytes
      await File(tempFilePath).writeAsBytes(List.filled(512, 0));

      final chunks = [
        ChunkState(start: 0, end: 1023, downloaded: 512),
        ChunkState(start: 1024, end: 2047, downloaded: 0),
      ];
      final state = TransferState(
        totalSize: 2048,
        threadCount: 2,
        chunks: chunks,
        status: DmxStateStatus.paused,
        pauseReason: PauseReason.userRequested,
      );

      await StateStore.save(
        tempFilePath,
        state,
        durable: true,
        taskId: 'task_durable_1',
      );

      final statePath =
          StateStore.pathFor(tempFilePath, taskId: 'task_durable_1');
      final stateFile = File(statePath);
      expect(await stateFile.exists(), isTrue);

      final loadedState = await StateStore.loadOrCreate(
        tempFilePath,
        url: 'https://example.com/test.bin',
        threadCount: 2,
        knownFileSize: 2048,
        taskId: 'task_durable_1',
      );

      expect(loadedState.state.status, equals(DmxStateStatus.paused));
      expect(loadedState.state.pauseReason, equals(PauseReason.userRequested));
      expect(loadedState.state.downloadedBytes, equals(512));
    });

    test(
        'saveTaskDebounced immediately writes paused tasks without batch timer debounce',
        () async {
      final dbService = DatabaseService.instance;
      await dbService.init(testPath: tempDir.path);
      final now = DateTime.now();

      final task = DownloadTask(
        id: 'paused_task_1',
        url: 'https://example.com/file.zip',
        fileName: 'file.zip',
        category: 'General',
        savePath: '/tmp',
        localFilePath: '/tmp/file.zip',
        tempFilePath: '/tmp/file.zip.dmxdownload',
        fileSize: 10000,
        downloadedBytes: 5000,
        status: DownloadStatus.paused,
        pauseReason: PauseReason.user,
        threadCount: 1,
        chunks: const [],
        createdAt: now,
        updatedAt: now,
      );

      await dbService.saveTaskDebounced(task);

      // Verify no pending debounce timer is holding this paused save
      expect(dbService.dbBatchTimer?.isActive ?? false, isFalse);

      final saved = await dbService.getTask('paused_task_1');
      expect(saved, isNotNull);
      expect(saved?.status, equals(DownloadStatus.paused));
      expect(saved?.downloadedBytes, equals(5000));
    });
  });
}
