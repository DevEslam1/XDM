import 'dart:io';

import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String tempDir;
  late String dbPath;
  late AppDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final sysTemp = Directory.systemTemp;
    tempDir = (await sysTemp.createTemp('dmx_wal_test_')).path;
    dbPath = p.join(tempDir, 'test.db');
    db = AppDatabase(dbPath);
  });

  tearDown(() async {
    await db.closeDatabase();
    final dir = Directory(tempDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  test('AppDatabase executes checkpointWal without error', () async {
    // Insert dummy task row to generate WAL writes
    await db.into(db.bookmarks).insert(
          BookmarksCompanion.insert(
            id: 'b1',
            title: 'Test',
            url: 'https://example.com',
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );

    final result = await db.checkpointWal(truncate: true);
    expect(result, isNonNegative);
  });

  test('AppDatabase cleanupStaleConnections validates connection health', () async {
    final isHealthy = await db.cleanupStaleConnections();
    expect(isHealthy, isTrue);
  });

  test('AppDatabase periodic checkpointer can be started and stopped', () async {
    db.startPeriodicWalCheckpointer(interval: const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    db.stopPeriodicWalCheckpointer();
    // No crashes or unhandled exceptions
    expect(true, isTrue);
  });

  test('DatabaseService exposes WAL management and connection health checks', () async {
    final dbService = DatabaseService();
    await dbService.init(testPath: tempDir);

    final isHealthy = await dbService.cleanupStaleConnections();
    expect(isHealthy, isTrue);

    final checkpointRes = await dbService.checkpointWal(truncate: true);
    expect(checkpointRes, isNonNegative);

    await dbService.dispose();
  });
}
