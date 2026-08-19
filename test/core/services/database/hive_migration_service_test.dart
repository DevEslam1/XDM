import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/hive_migration_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late HiveMigrationService migrationService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    migrationService = HiveMigrationService(db, prefs);
  });

  tearDown(() async {
    await db.close();
  });

  group('HiveMigrationService Interrupted Task Mapping (FIX-07)', () {
    test(
        '_taskToCompanion sets pauseReason = appRestarted and cycleState = paused for downloading resumable task',
        () {
      final task = DownloadTask(
        id: 'task-mig-1',
        fileName: 'file.zip',
        url: 'https://example.com/file.zip',
        fileSize: 10000,
        downloadedBytes: 5000,
        category: 'Archive',
        status: DownloadStatus.downloading,
        cycleState: CycleState.downloading,
        savePath: '/tmp/file.zip',
        localFilePath: '/tmp/file.zip',
        tempFilePath: '/tmp/file.zip.dmx',
        threadCount: 4,
        chunks: [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        supportsResume: true,
      );

      final companion = migrationService.taskToCompanionForTesting(task);

      expect(
          companion.pauseReason.value, equals(PauseReason.appRestarted.name));
      expect(companion.cycleState.value, equals(CycleState.paused.name));
      expect(companion.status.value, equals(DownloadStatus.paused.name));
    });
  });
}
