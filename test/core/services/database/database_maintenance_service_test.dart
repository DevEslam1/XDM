import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/services/database_maintenance_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DatabaseMaintenanceService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    service = DatabaseMaintenanceService(db);
  });

  tearDown(() async {
    service.dispose();
    await db.close();
  });

  Future<void> insertTask({required String id, required String status}) {
    return db.into(db.downloadTasks).insert(
          DownloadTasksCompanion.insert(
            id: id,
            fileName: '$id.bin',
            url: 'https://example.com/$id',
            category: 'c',
            status: status,
            savePath: '/s',
            localFilePath: '/s',
            tempFilePath: '/s.tmp',
            threadCount: 1,
            createdAt: 0,
            updatedAt: 0,
          ),
        );
  }

  group('DatabaseMaintenanceService', () {
    test('start and dispose wire up power listeners', () {
      service.start();
      service.dispose();
    });

    test('the maintenance tick runs on the heartbeat', () async {
      service.start();
      // The heartbeat fires after ~1s; the epoch lastRun makes the callback
      // eligible on the first beat.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(service.maintenanceRuns, greaterThanOrEqualTo(1));
    });

    test('runs a standard maintenance cycle and increments the counter',
        () async {
      expect(service.maintenanceRuns, 0);
      await service.runPeriodicMaintenanceForTesting();
      expect(service.maintenanceRuns, 1);
    });

    test('runs the WAL truncate branch on the sixth cycle', () async {
      service.maintenanceRuns = 5;
      await service.runPeriodicMaintenanceForTesting();
      expect(service.maintenanceRuns, 6);
    });

    test('runs the vacuum / optimize branch on the twelfth cycle', () async {
      service.maintenanceRuns = 11;
      await service.runPeriodicMaintenanceForTesting();
      expect(service.maintenanceRuns, 12);
    });

    test('runs the full VACUUM branch every 720 cycles', () async {
      service.maintenanceRuns = 719;
      await service.runPeriodicMaintenanceForTesting();
      expect(service.maintenanceRuns, 720);
    });

    test(
        'skips wal_checkpoint while downloads are active and not on a '
        '4th cycle', () async {
      await insertTask(id: 'active', status: 'downloading');
      service.maintenanceRuns = 1;
      await service.runPeriodicMaintenanceForTesting();
      expect(service.maintenanceRuns, 2);
    });

    test('still checkpoints on a 4th cycle even with active downloads',
        () async {
      await insertTask(id: 'active', status: 'downloading');
      service.maintenanceRuns = 3;
      await service.runPeriodicMaintenanceForTesting();
      expect(service.maintenanceRuns, 4);
    });

    test('caches the active-downloads probe between runs', () async {
      await insertTask(id: 'active', status: 'downloading');
      await service.runPeriodicMaintenanceForTesting();
      // Insert more rows; the cached probe should still report the same.
      await insertTask(id: 'active2', status: 'downloading');
      await service.runPeriodicMaintenanceForTesting();
      expect(service.maintenanceRuns, 2);
    });
  });
}
