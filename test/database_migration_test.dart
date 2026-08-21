import 'package:dmx/core/services/database/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('Database migration and initial setup sanity check', () async {
    expect(db.schemaVersion, equals(27));

    // Verify bookmarks table and operations work correctly
    await db.customStatement('''
      INSERT INTO bookmarks (id, title, url, folder, created_at)
      VALUES ('bm1', 'Google', 'https://google.com', NULL, 1700000000000)
    ''');

    final bookmarks = await db.select(db.bookmarks).get();
    expect(bookmarks.length, equals(1));
    expect(bookmarks.first.id, equals('bm1'));
    expect(bookmarks.first.createdAt, equals(1700000000000));

    // Verify browser_history table and index
    await db.customStatement('''
      INSERT INTO browser_history (url, title, visited_at)
      VALUES ('https://flutter.dev', 'Flutter', 1700000050000)
    ''');

    final history = await db.select(db.browserHistory).get();
    expect(history.length, equals(1));
    expect(history.first.visitedAt, equals(1700000050000));
  });
}
