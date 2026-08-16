import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/hive_migration_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase db;
  late SharedPreferences prefs;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_10k_benchmark_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = AppDatabase(p.join(tempDir.path, 'benchmark.sqlite'));
  });

  tearDown(() async {
    await Hive.close();
    await db.close();
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  group('HiveMigrationService 10k Benchmark (FIX-4)', () {
    test(
        '10k Hive entries migration does not block main isolate event loop for more than 500ms',
        () async {
      // 1. Populate Hive box with 10,000 bookmark entries
      final box =
          await Hive.openBox<dynamic>(HiveMigrationService.bookmarksBoxName);
      final entries = <String, Map<String, dynamic>>{};
      for (var i = 0; i < 10000; i++) {
        entries['bm_$i'] = {
          'id': 'bm_$i',
          'title': 'Bookmark $i',
          'url': 'https://example.com/page/$i',
          'folder': 'Default',
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        };
      }
      await box.putAll(entries);
      await box.close();

      // 2. Measure main isolate event loop responsiveness during migration
      var maxEventLoopLagMs = 0;
      var lastTick = DateTime.now();
      final ticker = Timer.periodic(const Duration(milliseconds: 10), (_) {
        final now = DateTime.now();
        final lag = now.difference(lastTick).inMilliseconds;
        maxEventLoopLagMs = max(maxEventLoopLagMs, lag);
        lastTick = now;
      });

      final migrationService = HiveMigrationService(db, prefs);
      try {
        await migrationService.migrate();
      } finally {
        ticker.cancel();
      }

      // Assert that migration completed
      expect(prefs.getBool(HiveMigrationService.migrationKey), isTrue);

      // Verify that the main isolate was never blocked for > 500ms
      expect(
        maxEventLoopLagMs,
        lessThan(500),
        reason:
            'Main isolate should not be blocked for >500ms during background migration',
      );
    });
  });
}
