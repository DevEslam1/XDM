import 'dart:io';

import 'package:dmx/core/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService dbService;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('db_maint_test_');
    dbService = DatabaseService();
    await dbService.init(testPath: tempDir.path);
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('DatabaseService Periodic Maintenance Cadence', () {
    test('executes maintenance cycles and increments run count', () async {
      expect(dbService.maintenanceRuns, 0);

      // Run 1: Standard cycle
      await dbService.runPeriodicMaintenanceForTesting();
      expect(dbService.maintenanceRuns, 1);

      // Advance to run 6: 6th cycle (WAL size evaluation)
      dbService.maintenanceRuns = 5;
      await dbService.runPeriodicMaintenanceForTesting();
      expect(dbService.maintenanceRuns, 6);

      // Advance to run 12: 12th cycle (vacuum & optimize)
      dbService.maintenanceRuns = 11;
      await dbService.runPeriodicMaintenanceForTesting();
      expect(dbService.maintenanceRuns, 12);
    });
  });
}
