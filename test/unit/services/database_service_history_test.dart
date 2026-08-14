import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dmx/core/services/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseService Browser History Debounce (DB-04)', () {
    late Directory tempDir;
    late DatabaseService dbService;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('db_history_test_');
      dbService = DatabaseService();
      await dbService.init(testPath: tempDir.path);
    });

    tearDown(() async {
      dbService.cancelPendingTimers();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('addBrowserHistory with immediate: true persists synchronously',
        () async {
      await dbService.addBrowserHistory({
        'url': 'https://example.com/page1',
        'title': 'Example Page 1',
      }, immediate: true);

      final count = await dbService.getVisitCount('https://example.com/page1');
      expect(count, equals(1));
    });

    test('addBrowserHistory debounces rapid writes for same URL', () async {
      await dbService.addBrowserHistory({
        'url': 'https://example.com/debounced',
        'title': 'Debounced Page Initial',
      });

      await dbService.addBrowserHistory({
        'url': 'https://example.com/debounced',
        'title': 'Debounced Page Final',
      });

      // Before timer fires, immediate DB query returns 0 visits
      final countImmediate =
          await dbService.getVisitCount('https://example.com/debounced');
      expect(countImmediate, equals(0));
    });
  });
}
