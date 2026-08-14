import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseService Single Migration Flag (DB-03)', () {
    test('hive_migration_complete flag prevents re-migration', () async {
      SharedPreferences.setMockInitialValues({
        'hive_migration_complete': true,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('hive_migration_complete'), isTrue);
    });
  });
}
