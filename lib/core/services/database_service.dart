import 'package:hive_flutter/hive_flutter.dart';

import '../../features/downloads/models/download_task.dart';

class DatabaseService {
  static const String downloadsBoxName = 'downloads';

  late final Box<dynamic> _downloadsBox;

  Future<void> init() async {
    _downloadsBox = await Hive.openBox<dynamic>(downloadsBoxName);
  }

  List<DownloadTask> loadTasks() {
    return _downloadsBox.values
        .whereType<Map>()
        .map((value) => DownloadTask.fromMap(Map<String, dynamic>.from(value)))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> saveTask(DownloadTask task) {
    return _downloadsBox.put(task.id, task.toMap());
  }

  Future<void> saveTasks(Iterable<DownloadTask> tasks) async {
    for (final task in tasks) {
      await saveTask(task);
    }
  }

  Future<void> deleteTask(String id) {
    return _downloadsBox.delete(id);
  }
}
