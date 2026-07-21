import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

part 'app_database.g.dart';

// Type Converters
class DoubleListConverter extends TypeConverter<List<double>, String> {
  const DoubleListConverter();
  @override
  List<double> fromSql(String fromDb) {
    if (fromDb.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(fromDb);
      if (decoded is List) {
        return decoded.map((e) => (e as num).toDouble()).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  @override
  String toSql(List<double> value) => jsonEncode(value);
}

class TorrentFilesConverter
    extends TypeConverter<List<Map<String, dynamic>>, String> {
  const TorrentFilesConverter();
  @override
  List<Map<String, dynamic>> fromSql(String fromDb) {
    if (fromDb.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(fromDb);
      if (decoded is List) {
        return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  @override
  String toSql(List<Map<String, dynamic>> value) {
    return jsonEncode(value);
  }
}

// Tables
@DataClassName('DbDownloadTask')
class DownloadTasks extends Table {
  TextColumn get id => text()();
  TextColumn get fileName => text()();
  TextColumn get url => text()();
  IntColumn get fileSize => integer().withDefault(const Constant(0))();
  IntColumn get downloadedBytes => integer().withDefault(const Constant(0))();
  RealColumn get speed => real().withDefault(const Constant(0.0))();
  IntColumn get eta => integer().nullable()();
  TextColumn get category => text()();
  TextColumn get status => text()();
  TextColumn get savePath => text()();
  TextColumn get localFilePath => text()();
  TextColumn get tempFilePath => text()();
  TextColumn get errorMessage => text().nullable()();
  IntColumn get threadCount => integer()();
  TextColumn get chunks => text().map(const DoubleListConverter())();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  TextColumn get completedAt => text().nullable()();
  TextColumn get scheduledAt => text().nullable()();
  BoolColumn get supportsResume => boolean().withDefault(const Constant(false))();
  IntColumn get speedLimitKbps => integer().withDefault(const Constant(0))();
  BoolColumn get seedingEnabled => boolean().withDefault(const Constant(false))();
  BoolColumn get seedingLimited => boolean().withDefault(const Constant(false))();
  IntColumn get seedingLimitKbps => integer().withDefault(const Constant(500))();
  TextColumn get torrentFiles => text()
      .map(NullAwareTypeConverter.wrap(const TorrentFilesConverter()))
      .nullable()();
  TextColumn get downloadPageUrl => text().nullable()();
  TextColumn get mergedAudioUrl => text().nullable()();
  IntColumn get audioSize => integer().withDefault(const Constant(0))();
  RealColumn get audioProgress => real().withDefault(const Constant(0.0))();
  BoolColumn get pausedByUser => boolean().withDefault(const Constant(false))();
  TextColumn get youtubeQualityPreset => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DbBookmark')
class Bookmarks extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get url => text()();
  TextColumn get folder => text().nullable()();
  TextColumn get createdAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DbBrowserHistory')
class BrowserHistory extends Table {
  TextColumn get id => text()();
  TextColumn get url => text()();
  TextColumn get title => text()();
  TextColumn get visitedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

LazyDatabase _openConnection(String path) {
  return LazyDatabase(() async {
    final file = File(path);
    return NativeDatabase.createInBackground(file, setup: (database) {
      database.execute('PRAGMA journal_mode=WAL;');
    });
  });
}

@DriftDatabase(tables: [DownloadTasks, Bookmarks, BrowserHistory])
class AppDatabase extends _$AppDatabase {
  AppDatabase(String path) : super(_openConnection(path));
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          // Migration logic for future schemaVersion updates
        },
      );
}
