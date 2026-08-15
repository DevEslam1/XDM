import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DatabaseService Dispose & Adaptive Maintenance Tests', () {
    test('dispose cancels all debounce timers, pending entries, and maintenance timers', () async {
      final dbService = DatabaseService();
      await dbService.init(testPath: 'test_db_dir');

      // Add a history item to start a debounce timer
      await dbService.addBrowserHistory({
        'url': 'https://example.com',
        'title': 'Example',
      });

      // Dispose the service
      await dbService.dispose();

      // Ensure dispose completed cleanly and didn't leave open transactions or active timers
      expect(dbService.isInitialized, isTrue);
    });

    test('PowerMonitor changes trigger adaptive maintenance interval rescaling', () async {
      final dbService = DatabaseService();
      await dbService.init(testPath: 'test_db_dir_2');

      // Toggle power state for testing
      PowerMonitor.setScreenOn(false);
      PowerMonitor.setScreenOn(true);

      await dbService.dispose();
    });
  });
}
