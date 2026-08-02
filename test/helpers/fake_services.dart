import 'package:flutter/material.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/permission_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/browser/models/bookmark.dart';

class FakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    return FakePlatformWebViewController(params);
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) {
    return FakePlatformWebViewWidget(params);
  }

  PlatformWebViewCookieManager createPlatformWebViewCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) {
    return FakePlatformWebViewCookieManager(params);
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    return FakePlatformNavigationDelegate(params);
  }
}

class FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  FakePlatformNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {}
}

class FakePlatformWebViewController extends PlatformWebViewController {
  FakePlatformWebViewController(super.params) : super.implementation();

  @override
  Future<void> loadRequest(LoadRequestParams params) async {}

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> setUserAgent(String? userAgent) async {}

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {}

  @override
  Future<void> enableZoom(bool enabled) async {}

  @override
  Future<void> setOnConsoleMessage(
    void Function(JavaScriptConsoleMessage consoleMessage) onConsoleMessage,
  ) async {}

  @override
  Future<void> setOnPlatformPermissionRequest(
    void Function(PlatformWebViewPermissionRequest request) onPermissionRequest,
  ) async {}

  @override
  Future<void> setOnScrollPositionChange(
    void Function(ScrollPositionChange scrollPositionChange)? onScrollPositionChange,
  ) async {}

  @override
  Future<String?> currentUrl() async => 'https://example.com';

  @override
  Future<String?> getTitle() async => 'Example Domain';

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<bool> canGoForward() async => false;

  @override
  Future<void> reload() async {}
}

class FakePlatformWebViewWidget extends PlatformWebViewWidget {
  FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

class FakePlatformWebViewCookieManager extends PlatformWebViewCookieManager {
  FakePlatformWebViewCookieManager(super.params) : super.implementation();
}

class FakeDatabaseService extends DatabaseService {
  final List<DownloadTask> _tasks = [];
  final List<Bookmark> _bookmarks = [];
  final List<Map<String, dynamic>> _history = [];

  FakeDatabaseService({List<DownloadTask>? initialTasks}) : super.forSubclass() {
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
