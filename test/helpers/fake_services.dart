import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/permission_service.dart';
import 'package:dmx/features/browser/models/bookmark.dart';
import 'package:dmx/features/downloads/models/download_task.dart';

export 'fake_download_engine.dart';
export 'fake_torrent_service.dart';
export 'scriptable_http_server.dart';

class FakeDatabaseService extends DatabaseService {
  final List<DownloadTask> _tasks = [];
  final List<Bookmark> _bookmarks = [];
  final List<Map<String, dynamic>> _history = [];

  FakeDatabaseService({List<DownloadTask>? initialTasks})
      : super.forSubclass() {
    if (initialTasks != null) {
      _tasks.addAll(initialTasks);
    }
  }

  Future<void> fakeInit({String? testPath}) async {}

  @override
  Future<List<DownloadTask>> loadTasks() async => List.unmodifiable(_tasks);

  @override
  Future<void> saveTask(DownloadTask task) async {
    _tasks.removeWhere((t) => t.id == task.id);
    _tasks.add(task);
  }

  @override
  Future<void> saveTasks(Iterable<DownloadTask> tasks) async {
    for (final task in tasks) {
      await saveTask(task);
    }
  }

  @override
  Future<void> deleteTask(String id) async {
    _tasks.removeWhere((t) => t.id == id);
  }

  @override
  Future<List<Bookmark>> loadBookmarks({String? searchQuery}) async =>
      List.unmodifiable(_bookmarks);

  @override
  Future<List<Bookmark>> searchBookmarks(String query, {int limit = 3}) async {
    final term = query.trim().toLowerCase();
    if (term.isEmpty) return [];
    return _bookmarks
        .where((b) =>
            b.title.toLowerCase().contains(term) ||
            b.url.toLowerCase().contains(term))
        .take(limit)
        .toList();
  }

  @override
  Future<void> saveBookmark(Bookmark bookmark) async {
    _bookmarks.removeWhere((b) => b.id == bookmark.id);
    _bookmarks.add(bookmark);
  }

  @override
  Future<void> deleteBookmark(String id) async {
    _bookmarks.removeWhere((b) => b.id == id);
  }

  Future<List<Map<String, dynamic>>> getHistory() async =>
      List.unmodifiable(_history);

  Future<void> addHistory(String title, String url) async {
    _history.add({
      'title': title,
      'url': url,
      'visitedAt': DateTime.now().toIso8601String(),
    });
  }

  Future<void> clearHistory() async {
    _history.clear();
  }
}

class FakeDownloadEngine extends DownloadEngine {
  final List<String> startedTasks = [];
  final List<String> pausedTasks = [];
  final List<String> cancelledTasks = [];

  FakeDownloadEngine() : super(enableCleanupTimer: false);

  void pause(String taskId) {
    pausedTasks.add(taskId);
  }

  void cancel(String taskId) {
    cancelledTasks.add(taskId);
  }
}

class FakePermissionService extends PermissionService {
  bool storageGranted = true;
  bool notificationGranted = true;

  @override
  Future<String> defaultDownloadDirectory() async => 'build/test_downloads';

  @override
  Future<bool> ensureStorageAccess() async => storageGranted;

  @override
  Future<bool> isStoragePermissionValid() async => storageGranted;

  @override
  Future<bool> isBatteryOptimizationExempt() async => true;

  @override
  Future<bool> requestBatteryOptimizationExemption() async => true;
}
