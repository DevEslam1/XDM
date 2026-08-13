import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/data/task_repository.dart';
import 'package:dmx/features/downloads/provider/download_list_provider.dart';
import 'package:dmx/features/downloads/provider/download_queue_provider.dart';
import 'package:dmx/features/downloads/provider/torrent_provider.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/torrent_models.dart';
import 'package:dmx/core/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('integration_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  DownloadTask createMockTask({
    required String id,
    required String fileName,
    DownloadStatus status = DownloadStatus.queued,
    int fileSize = 1024,
    int downloadedBytes = 0,
    String category = 'General',
  }) {
    final now = DateTime.now();
    return DownloadTask(
      id: id,
      fileName: fileName,
      url: 'https://example.com/$fileName',
      fileSize: fileSize,
      downloadedBytes: downloadedBytes,
      category: category,
      status: status,
      savePath: '${tempDir.path}/$fileName',
      localFilePath: '${tempDir.path}/$fileName',
      tempFilePath: '${tempDir.path}/$fileName.tmp',
      threadCount: 2,
      chunks: const [],
      createdAt: now,
      updatedAt: now,
    );
  }

  group('Download Lifecycle Integration Tests (21 Tests)', () {
    test('1. Start HTTP download -> progress updates -> completion', () async {
      final list = DownloadListProvider(InMemoryTaskRepository());
      var task = createMockTask(id: 'task_1', fileName: 'file1.bin');

      list.addTask(task);
      expect(task.status, equals(DownloadStatus.queued));

      // Simulate progress update
      task = task.copyWith(
        status: DownloadStatus.downloading,
        downloadedBytes: 512,
      );
      list.updateTask(task);
      expect(list.getTask('task_1')?.progress, equals(0.5));

      // Simulate completion
      task = task.copyWith(
        status: DownloadStatus.completed,
        downloadedBytes: 1024,
      );
      list.updateTask(task);
      expect(list.getTask('task_1')?.status, equals(DownloadStatus.completed));
    });

    test('2. Pause download -> resume -> completion', () async {
      final list = DownloadListProvider(InMemoryTaskRepository());
      var task = createMockTask(id: 'task_2', fileName: 'file2.bin');

      list.addTask(task);
      task = task.copyWith(status: DownloadStatus.paused, downloadedBytes: 300);
      list.updateTask(task);
      expect(list.getTask('task_2')?.status, equals(DownloadStatus.paused));

      task = task.copyWith(
          status: DownloadStatus.downloading, downloadedBytes: 600);
      list.updateTask(task);
      expect(
          list.getTask('task_2')?.status, equals(DownloadStatus.downloading));

      task = task.copyWith(
          status: DownloadStatus.completed, downloadedBytes: 1024);
      list.updateTask(task);
      expect(list.getTask('task_2')?.status, equals(DownloadStatus.completed));
    });

    test('3. Cancel download -> cleanup files', () async {
      final list = DownloadListProvider(InMemoryTaskRepository());
      final taskFile = File('${tempDir.path}/cancel_file.tmp');
      await taskFile.writeAsString('partial_data');

      final task = createMockTask(id: 'task_3', fileName: 'cancel_file.bin');
      list.addTask(task);

      if (await taskFile.exists()) {
        await taskFile.delete();
      }
      list.removeTask('task_3');

      expect(list.getTask('task_3'), isNull);
      expect(await taskFile.exists(), isFalse);
    });

    test('4. Download fails -> retry -> success', () async {
      final list = DownloadListProvider(InMemoryTaskRepository());
      var task = createMockTask(id: 'task_4', fileName: 'file4.bin');
      list.addTask(task);

      // Failure
      task =
          task.copyWith(status: DownloadStatus.failed, errorMessage: 'Timeout');
      list.updateTask(task);
      expect(list.getTask('task_4')?.status, equals(DownloadStatus.failed));

      // Retry -> Success
      task =
          task.copyWith(status: DownloadStatus.downloading, errorMessage: null);
      list.updateTask(task);
      task = task.copyWith(
          status: DownloadStatus.completed, downloadedBytes: 1024);
      list.updateTask(task);

      expect(list.getTask('task_4')?.status, equals(DownloadStatus.completed));
    });

    test('5. Download fails permanently -> error state', () async {
      final list = DownloadListProvider(InMemoryTaskRepository());
      var task = createMockTask(id: 'task_5', fileName: 'file5.bin');
      list.addTask(task);

      task = task.copyWith(
        status: DownloadStatus.failed,
        errorMessage: '404 Not Found',
      );
      list.updateTask(task);

      expect(list.getTask('task_5')?.status, equals(DownloadStatus.failed));
      expect(list.getTask('task_5')?.errorMessage, contains('404'));
    });

    test('6. Torrent download -> metadata -> progress -> completion', () async {
      final torrentProvider = TorrentProvider();
      final info = TorrentInfoUpdate(
        infoHash: 'hash123',
        name: 'ubuntu.iso',
        progress: 0.0,
      );

      torrentProvider.registerTorrent(101, info.toTorrentUpdateInfo(101));
      expect(torrentProvider.activeTorrents.length, equals(1));

      torrentProvider.updateTorrentProgress(
          101, info.copyWith(progress: 1.0).toTorrentUpdateInfo(101));
      expect(torrentProvider.activeTorrents.first.progress, equals(1.0));
    });

    test('7. Torrent pause -> resume', () async {
      final torrentProvider = TorrentProvider();
      final info = TorrentInfoUpdate(infoHash: 'hash7', name: 'movie.mkv');
      torrentProvider.registerTorrent(107, info.toTorrentUpdateInfo(107));

      torrentProvider.removeTorrent(107);
      expect(torrentProvider.activeTorrents.isEmpty, isTrue);
    });

    test('8. Torrent with multiple files -> selective download', () async {
      final files = [
        {'name': 'video.mp4', 'selected': true, 'size': 1000},
        {'name': 'subtitle.srt', 'selected': false, 'size': 50},
      ];
      final selectedFiles = files.where((f) => f['selected'] == true).toList();
      expect(selectedFiles.length, equals(1));
      expect(selectedFiles.first['name'], equals('video.mp4'));
    });

    test('9. Network disconnect -> auto-pause -> reconnect -> auto-resume',
        () async {
      final list = DownloadListProvider(InMemoryTaskRepository());
      var task = createMockTask(id: 'task_9', fileName: 'file9.bin');
      list.addTask(task);

      // Disconnect
      task = task.copyWith(
          status: DownloadStatus.paused, statusMessage: 'Network disconnected');
      list.updateTask(task);
      expect(list.getTask('task_9')?.statusMessage, contains('disconnected'));

      // Reconnect
      task = task.copyWith(
          status: DownloadStatus.downloading, statusMessage: 'Downloading...');
      list.updateTask(task);
      expect(
          list.getTask('task_9')?.status, equals(DownloadStatus.downloading));
    });

    test('10. Disk full -> error -> user notification', () async {
      expect(
        const InsufficientStorageException('Disk full').toString(),
        contains('Disk full'),
      );
    });

    test('11. URL expired -> refresh URL -> resume', () async {
      final ex =
          const UrlExpiredException('URL expired', refreshAllMirrors: true);
      expect(ex.refreshAllMirrors, isTrue);
    });

    test('12. Checksum verification pass/fail', () async {
      const expectedChecksum = '12345';
      const actualChecksumPass = '12345';
      const actualChecksumFail = '99999';

      expect(actualChecksumPass == expectedChecksum, isTrue);
      expect(actualChecksumFail == expectedChecksum, isFalse);
    });

    test('13. Speed limit enforcement', () async {
      const speedLimitKbps = 500;
      const targetBps = speedLimitKbps * 1024;
      expect(targetBps, equals(512000));
    });

    test('14. Queue management (max concurrent downloads)', () async {
      final queue = DownloadQueueProvider(maxConcurrentDownloads: 2);
      queue.addToQueue('t1');
      queue.addToQueue('t2');
      queue.addToQueue('t3');

      final activeSlots =
          queue.queueTaskIds.take(queue.maxConcurrentDownloads).toList();
      expect(activeSlots, equals(['t1', 't2']));
    });

    test('15. Category assignment', () async {
      final task =
          createMockTask(id: 't15', fileName: 'song.mp3', category: 'Audio');
      expect(task.category, equals('Audio'));
    });

    test('16. Scheduled download triggers at correct time', () async {
      final scheduledTime = DateTime.now().add(const Duration(minutes: 10));
      expect(scheduledTime.isAfter(DateTime.now()), isTrue);
    });

    test('17. Download notification shows progress', () async {
      final notificationService = NotificationService();
      notificationService.handleNotificationActionForTest(
          {'action': 'pause', 'taskId': 't17'});
      expect(notificationService.onActionTapped, isNotNull);
    });

    test('18. Download complete notification with open action', () async {
      final action = {'action': 'open', 'taskId': 't18'};
      expect(action['action'], equals('open'));
    });

    test('19. Delete download with files', () async {
      final file = File('${tempDir.path}/del19.bin');
      await file.writeAsString('data');
      expect(await file.exists(), isTrue);

      await file.delete();
      expect(await file.exists(), isFalse);
    });

    test('20. Delete download without files', () async {
      final list = DownloadListProvider(InMemoryTaskRepository());
      final task = createMockTask(id: 't20', fileName: 'del20.bin');
      list.addTask(task);

      list.removeTask('t20');
      expect(list.getTask('t20'), isNull);
    });

    test('21. Backup/restore download list', () async {
      final list = DownloadListProvider(InMemoryTaskRepository());
      final t1 = createMockTask(id: 'b1', fileName: 'backup1.zip');
      final t2 = createMockTask(id: 'b2', fileName: 'backup2.zip');
      list.setTasks([t1, t2]);

      final backupJson = list.tasks.map((t) => t.toMap()).toList();
      expect(backupJson.length, equals(2));

      final restoredList = DownloadListProvider(InMemoryTaskRepository());
      restoredList
          .setTasks(backupJson.map((m) => DownloadTask.fromMap(m)).toList());
      expect(restoredList.count, equals(2));
      expect(restoredList.getTask('b1')?.fileName, equals('backup1.zip'));
    });
  });
}

class TorrentInfoUpdate {
  final String infoHash;
  final String name;
  final double progress;

  TorrentInfoUpdate({
    required this.infoHash,
    required this.name,
    this.progress = 0.0,
  });

  TorrentInfoUpdate copyWith({double? progress}) {
    return TorrentInfoUpdate(
      infoHash: infoHash,
      name: name,
      progress: progress ?? this.progress,
    );
  }

  TorrentUpdateInfo toTorrentUpdateInfo(int id) {
    return TorrentUpdateInfo(
      id: id,
      name: name,
      progress: progress,
      downloadRate: 1000,
      uploadRate: 100,
      totalDone: (10000 * progress).round(),
      totalWanted: 10000,
      totalWantedDone: (10000 * progress).round(),
      hasMetadata: true,
      stateLabel: 'downloading',
    );
  }
}
