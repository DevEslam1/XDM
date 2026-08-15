import 'dart:io';

import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/hive_migration_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HiveMigrationService Idempotency (P2-8)', () {
    late AppDatabase db;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('hive_mig_test');
      Hive.init(tempDir.path);
      SharedPreferences.setMockInitialValues({});
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
      await Hive.close();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Calling migrate() repeatedly is safe and idempotent', () async {
      final prefs = await SharedPreferences.getInstance();
      final service = HiveMigrationService(db, prefs);

      // Run 1st migration
      await service.migrate();
      expect(prefs.getBool(HiveMigrationService.migrationKey), isTrue);

      // Run 2nd migration - should immediately return and remain true
      await service.migrate();
      expect(prefs.getBool(HiveMigrationService.migrationKey), isTrue);

      // Run 3rd migration
      await service.migrate();
      expect(prefs.getBool(HiveMigrationService.migrationKey), isTrue);
    });
  });
}
