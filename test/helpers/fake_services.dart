import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/permission_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/browser/models/bookmark.dart';

class FakeDatabaseService extends DatabaseService {
  final List<DownloadTask> _tasks = [];
  final List<Bookmark> _bookmarks = [];
  final List<Map<String, dynamic>> _history = [];

  FakeDatabaseService() : super.forSubclass();

  Future<void> fakeInit({String? testPath}) async {}

  @override
  Future<List<DownloadTask>> loadTasks() async => List.unmodifiable(_tasks);

  @override
  Future<void> saveTask(DownloadTask task) async {
    _tasks.removeWhere((t) => t.id == task.id);
    _tasks.add(task);
  }

  @override
  Future<void> deleteTask(String id) async {
    _tasks.removeWhere((t) => t.id == id);
  }

  @override
  Future<List<Bookmark>> loadBookmarks() async => List.unmodifiable(_bookmarks);

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

  Future<bool> hasStoragePermission() async => storageGranted;
  Future<bool> requestStoragePermission() async => storageGranted;
  Future<bool> hasNotificationPermission() async => notificationGranted;
  Future<bool> requestNotificationPermission() async => notificationGranted;
}
