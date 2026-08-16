import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseService Hardening (Sprint 1)', () {
    test('_rowToTask maps unrecognised status to DownloadStatus.paused', () {
      final dbService = DatabaseService.instance;
      const fakeRow = DbDownloadTask(
        id: 'test-corrupt-status',
        url: 'https://example.com/file.zip',
        fileName: 'file.zip',
        fileSize: 1000,
        downloadedBytes: 0,
        speed: 0,
        category: 'General',
        savePath: '/downloads/file.zip',
        localFilePath: '/downloads/file.zip',
        tempFilePath: '/downloads/file.zip.dmx',
        status: 'some_unknown_corrupted_status',
        threadCount: 1,
        createdAt: 0,
        updatedAt: 0,
        supportsResume: true,
        speedLimitKbps: 0,
        seedingEnabled: false,
        seedingLimited: false,
        seedingLimitKbps: 0,
        audioSize: 0,
        audioDownloadedBytes: 0,
        videoStreamSize: 0,
        audioProgress: 0,
        pausedByUser: false,
        isAppUpdate: false,
        uploadedBytes: 0,
        priority: 0,
        queueOrder: 0,
      );

      final task = dbService.rowToTaskForTesting(fakeRow);
      expect(task.status, equals(DownloadStatus.paused));
    });
  });
}
