import 'dart:io';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late DatabaseService dbService;
  late SettingsProvider settingsProvider;

  setUp(() async {
    setupTestPluginMocks();
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('kill_matrix_test_');
    dbService = DatabaseService.instance;
    await dbService.init(testPath: ':memory:');
    settingsProvider = SettingsProvider.instance;
    await settingsProvider.load();
  });

  tearDown(() async {
    dbService.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Phase 5 — Kill -9 Crash Matrix & Data-Loss Hardening', () {
    test(
        'Matrix Case 1: Kill -9 Crash at 10% progress -> Zero byte loss on recovery',
        () async {
      const totalSize = 10 * 1024 * 1024; // 10 MB
      const threadCount = 4;
      const targetDownloaded = 1 * 1024 * 1024; // 1 MB (10%)
      final tempFilePath = '${tempDir.path}/task_10pct.dmxpart';
      final localFilePath = '${tempDir.path}/task_10pct.bin';

      // Write physical bytes to temp file on disk
      final tempFile = File(tempFilePath);
      final raf = await tempFile.open(mode: FileMode.write);
      await raf.truncate(targetDownloaded);
      await raf.close();

      // Write initial state and log 10% progress in journal before sudden kill
      final initialChunks = [
        ChunkState(start: 0, end: 2621439, downloaded: targetDownloaded),
        ChunkState(start: 2621440, end: 5242879, downloaded: 0),
        ChunkState(start: 5242880, end: 7864319, downloaded: 0),
        ChunkState(start: 7864320, end: 10485759, downloaded: 0),
      ];
      final state = TransferState(
        totalSize: totalSize,
        threadCount: threadCount,
        url: 'https://example.com/file_10pct.bin',
        chunks: initialChunks,
      );
      await StateStore.save(tempFilePath, state,
          durable: true, taskId: 'task-10');

      final journal = DownloadJournal('$tempFilePath.journal');
      await journal.open();
      await journal.writeInit(threadCount, totalSize);
      await journal.recordChunkProgress(0, targetDownloaded);
      await journal.flushAndSync();
      await journal
          .close(); // Simulates fsync flush to disk right before kill -9

      // Seed task into database as downloading
      final task = DownloadTask(
        id: 'task-10',
        url: 'https://example.com/file_10pct.bin',
        fileName: 'file_10pct.bin',
        savePath: localFilePath,
        localFilePath: localFilePath,
        tempFilePath: tempFilePath,
        fileSize: totalSize,
        downloadedBytes: 0, // Stale DB value before crash
        status: DownloadStatus.downloading,
        category: 'other',
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
        updatedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        threadCount: threadCount,
        chunks: const [],
        speed: 1024 * 1024,
      );
      await dbService.saveTask(task);

      // Simulate App Restart & Startup Reconciliation Pipeline
      final provider = DownloadProvider(
        databaseService: dbService,
        settingsProvider: settingsProvider,
        enableBackgroundTimers: false,
      );
      await provider.load(pauseOrphanDownloads: true, autoResume: false);

      // Assert zero byte data loss and proper recovery
      final recoveredTask = provider.findTaskById('task-10');
      expect(recoveredTask, isNotNull);
      expect(recoveredTask!.downloadedBytes, equals(targetDownloaded));
      expect(recoveredTask.status, equals(DownloadStatus.paused));
      expect(recoveredTask.pauseReason, equals(PauseReason.appRestarted));

      // Verify DB was updated with disk truth
      final dbTask = await dbService.getTask('task-10');
      expect(dbTask!.downloadedBytes, equals(targetDownloaded));
      expect(dbTask.status, equals(DownloadStatus.paused));

      provider.dispose();
    });

    test(
        'Matrix Case 2: Kill -9 Crash at 50% progress -> Zero byte loss on recovery',
        () async {
      const totalSize = 20 * 1024 * 1024; // 20 MB
      const threadCount = 4;
      const chunkSize = totalSize ~/ threadCount; // 5 MB per chunk
      const targetDownloaded = 10 * 1024 * 1024; // 10 MB (50%)
      final tempFilePath = '${tempDir.path}/task_50pct.dmxpart';
      final localFilePath = '${tempDir.path}/task_50pct.bin';

      final tempFile = File(tempFilePath);
      final raf = await tempFile.open(mode: FileMode.write);
      await raf.truncate(targetDownloaded);
      await raf.close();

      final chunks = [
        ChunkState(
            start: 0,
            end: chunkSize - 1,
            downloaded: chunkSize), // 5MB complete
        ChunkState(
            start: chunkSize,
            end: 2 * chunkSize - 1,
            downloaded: chunkSize), // 5MB complete
        ChunkState(start: 2 * chunkSize, end: 3 * chunkSize - 1, downloaded: 0),
        ChunkState(start: 3 * chunkSize, end: totalSize - 1, downloaded: 0),
      ];
      final state = TransferState(
        totalSize: totalSize,
        threadCount: threadCount,
        url: 'https://example.com/file_50pct.bin',
        chunks: chunks,
      );
      await StateStore.save(tempFilePath, state,
          durable: true, taskId: 'task-50');

      final journal = DownloadJournal('$tempFilePath.journal');
      await journal.open();
      await journal.writeInit(threadCount, totalSize);
      await journal.recordChunkProgress(0, chunkSize);
      await journal.recordChunkProgress(1, chunkSize);
      await journal.flushAndSync();
      await journal.close();

      final task = DownloadTask(
        id: 'task-50',
        url: 'https://example.com/file_50pct.bin',
        fileName: 'file_50pct.bin',
        savePath: localFilePath,
        localFilePath: localFilePath,
        tempFilePath: tempFilePath,
        fileSize: totalSize,
        downloadedBytes: 2 * 1024 * 1024, // Stale DB value (2MB)
        status: DownloadStatus.downloading,
        category: 'other',
        createdAt: DateTime.now().subtract(const Duration(minutes: 10)),
        updatedAt: DateTime.now().subtract(const Duration(minutes: 10)),
        threadCount: threadCount,
        chunks: const [],
        speed: 2 * 1024 * 1024,
      );
      await dbService.saveTask(task);

      final provider = DownloadProvider(
        databaseService: dbService,
        settingsProvider: settingsProvider,
        enableBackgroundTimers: false,
      );
      await provider.load(pauseOrphanDownloads: true, autoResume: false);

      final recoveredTask = provider.findTaskById('task-50');
      expect(recoveredTask, isNotNull);
      expect(recoveredTask!.downloadedBytes, equals(targetDownloaded));
      expect(recoveredTask.status, equals(DownloadStatus.paused));

      final stateResult = await StateStore.loadOrCreate(
        tempFilePath,
        url: task.url,
        threadCount: threadCount,
        knownFileSize: totalSize,
        taskId: 'task-50',
      );
      expect(stateResult.state.chunks[0].isComplete, isTrue);
      expect(stateResult.state.chunks[1].isComplete, isTrue);
      expect(stateResult.state.chunks[2].downloaded, equals(0));
      expect(stateResult.state.chunks[3].downloaded, equals(0));

      provider.dispose();
    });

    test(
        'Matrix Case 3: Kill -9 Crash at 99% progress -> Zero byte loss, only 1% left',
        () async {
      const totalSize = 100 * 1024 * 1024; // 100 MB
      const threadCount = 4;
      const chunkSize = totalSize ~/ threadCount; // 25 MB per chunk
      const chunk3Downloaded = 24 * 1024 * 1024; // 24 MB out of 25 MB
      const targetDownloaded = 3 * chunkSize + chunk3Downloaded; // 99 MB (99%)
      final tempFilePath = '${tempDir.path}/task_99pct.dmxpart';
      final localFilePath = '${tempDir.path}/task_99pct.bin';

      final tempFile = File(tempFilePath);
      final raf = await tempFile.open(mode: FileMode.write);
      await raf.truncate(targetDownloaded);
      await raf.close();

      final chunks = [
        ChunkState(
            start: 0, end: chunkSize - 1, downloaded: chunkSize), // 25 MB
        ChunkState(
            start: chunkSize,
            end: 2 * chunkSize - 1,
            downloaded: chunkSize), // 25 MB
        ChunkState(
            start: 2 * chunkSize,
            end: 3 * chunkSize - 1,
            downloaded: chunkSize), // 25 MB
        ChunkState(
            start: 3 * chunkSize,
            end: totalSize - 1,
            downloaded: chunk3Downloaded), // 24 MB
      ];
      final state = TransferState(
        totalSize: totalSize,
        threadCount: threadCount,
        url: 'https://example.com/file_99pct.bin',
        chunks: chunks,
      );
      await StateStore.save(tempFilePath, state,
          durable: true, taskId: 'task-99');

      final journal = DownloadJournal('$tempFilePath.journal');
      await journal.open();
      await journal.writeInit(threadCount, totalSize);
      await journal.writeCheckpoint(
          [chunkSize, chunkSize, chunkSize, chunk3Downloaded], totalSize);
      await journal.flushAndSync();
      await journal.close();

      final task = DownloadTask(
        id: 'task-99',
        url: 'https://example.com/file_99pct.bin',
        fileName: 'file_99pct.bin',
        savePath: localFilePath,
        localFilePath: localFilePath,
        tempFilePath: tempFilePath,
        fileSize: totalSize,
        downloadedBytes: 50 * 1024 * 1024,
        status: DownloadStatus.downloading,
        category: 'other',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        threadCount: threadCount,
        chunks: const [],
        speed: 5 * 1024 * 1024,
      );
      await dbService.saveTask(task);

      final provider = DownloadProvider(
        databaseService: dbService,
        settingsProvider: settingsProvider,
        enableBackgroundTimers: false,
      );
      await provider.load(pauseOrphanDownloads: true, autoResume: false);

      final recoveredTask = provider.findTaskById('task-99');
      expect(recoveredTask, isNotNull);
      expect(recoveredTask!.downloadedBytes, equals(targetDownloaded));
      expect(recoveredTask.status, equals(DownloadStatus.paused));

      provider.dispose();
    });

    test(
        'Matrix Case 4: Kill -9 Crash during final rename/move -> Target recognized, completed',
        () async {
      const totalSize = 5 * 1024 * 1024; // 5 MB
      final localFilePath = '${tempDir.path}/final_file.bin';
      final tempFilePath = '${tempDir.path}/final_file.bin.dmxpart';

      // Simulate that the file rename to destination completed on disk, but process crashed before DB updated
      final localFile = File(localFilePath);
      final raf = await localFile.open(mode: FileMode.write);
      await raf.truncate(totalSize);
      await raf.close();

      final task = DownloadTask(
        id: 'task-rename-crash',
        url: 'https://example.com/final_file.bin',
        fileName: 'final_file.bin',
        savePath: localFilePath,
        localFilePath: localFilePath,
        tempFilePath: tempFilePath,
        fileSize: totalSize,
        downloadedBytes: totalSize,
        status: DownloadStatus
            .downloading, // DB still recorded downloading when crash occurred
        category: 'other',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        threadCount: 2,
        chunks: const [],
        speed: 1024 * 1024,
      );
      await dbService.saveTask(task);

      final provider = DownloadProvider(
        databaseService: dbService,
        settingsProvider: settingsProvider,
        enableBackgroundTimers: false,
      );
      await provider.load(pauseOrphanDownloads: true, autoResume: false);

      final recoveredTask = provider.findTaskById('task-rename-crash');
      expect(recoveredTask, isNotNull);
      expect(recoveredTask!.status, equals(DownloadStatus.completed));
      expect(recoveredTask.downloadedBytes, equals(totalSize));

      final dbTask = await dbService.getTask('task-rename-crash');
      expect(dbTask!.status, equals(DownloadStatus.completed));
      expect(dbTask.downloadedBytes, equals(totalSize));

      provider.dispose();
    });

    test(
        'Matrix Case 5: Kill -9 Crash during DB write -> Journal/Disk truth overwrites stale DB',
        () async {
      const totalSize = 10 * 1024 * 1024;
      const threadCount = 2;
      const diskBytes = 6 * 1024 * 1024; // 6 MB on disk (60%)
      final tempFilePath = '${tempDir.path}/task_db_crash.dmxpart';
      final localFilePath = '${tempDir.path}/task_db_crash.bin';

      final tempFile = File(tempFilePath);
      final raf = await tempFile.open(mode: FileMode.write);
      await raf.truncate(diskBytes);
      await raf.close();

      final chunks = [
        ChunkState(start: 0, end: 5242879, downloaded: 5242880), // 5MB
        ChunkState(start: 5242880, end: 10485759, downloaded: 1048576), // 1MB
      ];
      final state = TransferState(
        totalSize: totalSize,
        threadCount: threadCount,
        url: 'https://example.com/file_db_crash.bin',
        chunks: chunks,
      );
      await StateStore.save(tempFilePath, state,
          durable: true, taskId: 'task-db-crash');

      final journal = DownloadJournal('$tempFilePath.journal');
      await journal.open();
      await journal.writeInit(threadCount, totalSize);
      await journal.writeCheckpoint([5242880, 1048576], totalSize);
      await journal.flushAndSync();
      await journal.close();

      // DB has stale progress from 2 minutes earlier (2MB)
      final task = DownloadTask(
        id: 'task-db-crash',
        url: 'https://example.com/file_db_crash.bin',
        fileName: 'file_db_crash.bin',
        savePath: localFilePath,
        localFilePath: localFilePath,
        tempFilePath: tempFilePath,
        fileSize: totalSize,
        downloadedBytes: 2 * 1024 * 1024, // 2MB in DB
        status: DownloadStatus.downloading,
        category: 'other',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        threadCount: threadCount,
        chunks: const [],
        speed: 1024 * 1024,
      );
      await dbService.saveTask(task);

      // Boot replay pipeline: Journal -> Disk -> DB -> UI
      final provider = DownloadProvider(
        databaseService: dbService,
        settingsProvider: settingsProvider,
        enableBackgroundTimers: false,
      );
      await provider.load(pauseOrphanDownloads: true, autoResume: false);

      final recovered = provider.findTaskById('task-db-crash');
      expect(recovered, isNotNull);
      expect(recovered!.downloadedBytes,
          equals(diskBytes)); // Reconciled from 2MB to 6MB
      expect(recovered.status, equals(DownloadStatus.paused));

      final updatedDb = await dbService.getTask('task-db-crash');
      expect(updatedDb!.downloadedBytes, equals(diskBytes));
      expect(updatedDb.status, equals(DownloadStatus.paused));

      provider.dispose();
    });

    test(
        'Matrix Case 6: Kill -9 during rename of UNKNOWN-length download -> .dmxdone marker recognized, completed',
        () async {
      // Unknown Content-Length: fileSize is 0. The size-based reconcile gate
      // (fileSize > 0) structurally cannot recognize completion, so the durable
      // `.dmxdone` marker written by _finalize is the only recovery signal.
      const downloadedSize = 3 * 1024 * 1024; // 3 MB actually written
      final localFilePath = '${tempDir.path}/unknown_len.bin';
      final tempFilePath = '${tempDir.path}/unknown_len.bin.dmxpart';

      // Rename to final destination completed on disk...
      final localFile = File(localFilePath);
      final raf = await localFile.open(mode: FileMode.write);
      await raf.truncate(downloadedSize);
      await raf.close();

      // ...and _finalize wrote the durable completion marker before crash,
      // but the DB was never updated (still 'downloading', fileSize 0, and the
      // StateStore snapshot was already removed).
      await File('$tempFilePath.dmxdone')
          .writeAsString('$downloadedSize', flush: true);

      final task = DownloadTask(
        id: 'task-unknown-len',
        url: 'https://example.com/unknown_len.bin',
        fileName: 'unknown_len.bin',
        savePath: localFilePath,
        localFilePath: localFilePath,
        tempFilePath: tempFilePath,
        fileSize: 0, // Unknown Content-Length
        downloadedBytes: 0,
        status: DownloadStatus.downloading,
        category: 'other',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        threadCount: 1,
        chunks: const [],
        speed: 1024 * 1024,
      );
      await dbService.saveTask(task);

      final provider = DownloadProvider(
        databaseService: dbService,
        settingsProvider: settingsProvider,
        enableBackgroundTimers: false,
      );
      await provider.load(pauseOrphanDownloads: true, autoResume: false);

      final recoveredTask = provider.findTaskById('task-unknown-len');
      expect(recoveredTask, isNotNull);
      expect(recoveredTask!.status, equals(DownloadStatus.completed));
      expect(recoveredTask.downloadedBytes, equals(downloadedSize));
      // fileSize was 0; reconcile adopts the marker's byte count.
      expect(recoveredTask.fileSize, equals(downloadedSize));

      final dbTask = await dbService.getTask('task-unknown-len');
      expect(dbTask!.status, equals(DownloadStatus.completed));
      expect(dbTask.downloadedBytes, equals(downloadedSize));

      // Marker must be consumed so it can't falsely reconcile a future re-download.
      expect(await File('$tempFilePath.dmxdone').exists(), isFalse);

      provider.dispose();
    });
  });
}
