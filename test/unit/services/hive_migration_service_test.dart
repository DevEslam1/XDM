import 'dart:io';

import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/hive_migration_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tempDir;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tempDir = await Directory.systemTemp.createTemp('hive_mig_test_');
    Hive.init(tempDir.path);
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('HiveMigrationService', () {
    test('migrate marks migration complete when boxes are empty or absent', () async {
      final migration = HiveMigrationService(db, prefs);
      await migration.migrate();

      expect(prefs.getBool(HiveMigrationService.migrationKey), isTrue);
    });

    test('skips migration when already marked complete', () async {
      await prefs.setBool(HiveMigrationService.migrationKey, true);
      final migration = HiveMigrationService(db, prefs);
      await migration.migrate();

      expect(prefs.getBool(HiveMigrationService.migrationKey), isTrue);
    });
  });
}
