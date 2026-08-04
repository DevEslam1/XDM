import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:logging/logging.dart';
import '../app_theme.dart';
import '../../features/categories/screens/category_detail_screen.dart';
import '../../features/details/screens/details_screen.dart';
import '../../features/downloads/models/download_task.dart';
import '../../features/downloads/provider/download_provider.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../shared/widgets/themed_snackbar.dart';
import '../utils/file_opener.dart';
import 'share_url_handler.dart';
import 'widget_data_bridge.dart';

/// Handles `dmx://` deep links launched from the launcher widgets.
///
/// Native sides (Android `MainActivity`, iOS `SceneDelegate`) forward the
/// incoming URL over the shared `com.dmx.app/widget_bridge` channel via the
/// `onOpenUrl` method; [init] registers that handler.
///
/// Supported routes:
///   `dmx://downloads`                     → open the app
///   `dmx://download/<task-id>`            → open task details
///   `dmx://toggle/<task-id>`              → toggle task pause/resume
///   `dmx://pause/<task-id>`               → pause task
///   `dmx://resume/<task-id>`              → resume task
///   `dmx://open/<task-id>`                → open completed downloaded file
///   `dmx://settings`                      → open settings
///   `dmx://settings/<section>`            → open settings section (general, network, appearance, advanced)
///   `dmx://category/<name>`               → open category detail screen
///   `dmx://add?url=<encoded-http(s)-url>` → show the add-download flow
///   `dmx://share?url=<encoded-url>`       → handle shared URL
///   `dmx://pause_all` / `dmx://pause-all`  → pause all downloads
///   `dmx://resume_all` / `dmx://resume-all` → resume all downloads
class WidgetDeepLinkHandler {
  static final _log = Logger('WidgetDeepLinkHandler');

  /// Global navigator of the app, used to push screens from cold starts.
  static GlobalKey<NavigatorState>? navigatorKey;

  /// Registers the native→Flutter deep link channel. Call once at startup,
  /// after the navigator key is attached to the [MaterialApp].
  static void init({GlobalKey<NavigatorState>? navigator}) {
    navigatorKey = navigator;
    WidgetDataBridge.channel.setMethodCallHandler((call) async {
      if (call.method == 'onOpenUrl') {
        handleUrl(call.arguments as String? ?? '');
      }
    });
  }

  static void handleUrl(String url) {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme.toLowerCase() != 'dmx') return;

    final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;

    switch (uri.host.toLowerCase()) {
      case 'downloads':
        _showMessage('DMX Downloads');
        break;
      case 'download':
        if (id != null && id.isNotEmpty) _openTaskDetails(id);
        break;
      case 'toggle':
        if (id != null && id.isNotEmpty) _toggleTask(id);
        break;
      case 'pause':
        if (id != null && id.isNotEmpty) _pauseTask(id);
        break;
      case 'resume':
        if (id != null && id.isNotEmpty) _resumeTask(id);
        break;
      case 'open':
        if (id != null && id.isNotEmpty) _openTaskFile(id);
        break;
      case 'settings':
        navigatorKey?.currentState?.push(
          MaterialPageRoute<void>(
            builder: (_) => SettingsScreen(initialSection: id),
          ),
        );
        break;
      case 'category':
        if (id != null && id.isNotEmpty) _openCategoryDetail(id);
        break;
      case 'add':
      case 'share':
        final target = uri.queryParameters['url'];
        if (target != null && target.isNotEmpty) {
          _handleAddUrl(target);
        }
        break;
      case 'pause_all':
      case 'pause-all':
        _toggleAll(pause: true);
        break;
      case 'resume_all':
      case 'resume-all':
        _toggleAll(pause: false);
        break;
      default:
        _log.fine('Unhandled dmx:// route: ${uri.host}');
    }
  }

  static void _openCategoryDetail(String categoryName) {
    final navigator = navigatorKey?.currentState;
    if (navigator == null) return;

    final nameLower = categoryName.trim().toLowerCase();
    String normalizedName = 'Other';
    IconData icon = Icons.insert_drive_file_outlined;
    Color color = AppTheme.neonBlue;

    switch (nameLower) {
      case 'video':
        normalizedName = 'Video';
        icon = Icons.movie_outlined;
        color = AppTheme.neonBlue;
        break;
      case 'audio':
        normalizedName = 'Audio';
        icon = Icons.audiotrack_outlined;
        color = AppTheme.neonViolet;
        break;
      case 'document':
      case 'documents':
        normalizedName = 'Document';
        icon = Icons.description_outlined;
        color = AppTheme.neonGreen;
        break;
      case 'archive':
      case 'archives':
        normalizedName = 'Archive';
        icon = Icons.folder_zip_outlined;
        color = AppTheme.neonAmber;
        break;
      case 'apk':
      case 'apks':
        normalizedName = 'APK';
        icon = Icons.android_outlined;
        color = const Color(0xFFF15BB5);
        break;
      default:
        normalizedName = categoryName;
        icon = Icons.insert_drive_file_outlined;
        color = AppTheme.textSecondary;
        break;
    }

    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => CategoryDetailScreen(
          categoryName: normalizedName,
          categoryColor: color,
          categoryIcon: icon,
        ),
      ),
    );
  }

  static void _openTaskDetails(String taskId) {
    final navigator = navigatorKey?.currentState;
    if (navigator == null) return;
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => DetailsScreen(taskId: taskId)),
    );
  }

  static void _toggleTask(String taskId) {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null) return;
    final provider = Provider.of<DownloadProvider>(ctx, listen: false);
    final task = provider.findTaskById(taskId);
    if (task == null) return;

    if (task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued) {
      provider.pauseTask(taskId);
    } else if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.failed) {
      provider.resumeTask(taskId);
    } else if (task.status == DownloadStatus.completed) {
      _openTaskFile(taskId);
    }
  }

  static void _pauseTask(String taskId) {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null) return;
    final provider = Provider.of<DownloadProvider>(ctx, listen: false);
    provider.pauseTask(taskId);
  }

  static void _resumeTask(String taskId) {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null) return;
    final provider = Provider.of<DownloadProvider>(ctx, listen: false);
    provider.resumeTask(taskId);
  }

  static Future<void> _openTaskFile(String taskId) async {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null) return;
    final provider = Provider.of<DownloadProvider>(ctx, listen: false);
    final settings = Provider.of<SettingsProvider>(ctx, listen: false);
    final task = provider.findTaskById(taskId);
    if (task == null) return;

    if (task.status == DownloadStatus.completed) {
      await openFile(ctx, task.localFilePath, settings);
    } else {
      _openTaskDetails(taskId);
    }
  }

  static void _handleAddUrl(String url) {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null) return;
    ShareUrlHandler.handle(ctx, url, isShareLaunch: false);
  }

  static void _toggleAll({required bool pause}) {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null) return;
    final provider = Provider.of<DownloadProvider>(ctx, listen: false);
    if (pause) {
      provider.pauseAllTasks();
    } else {
      provider.resumeAllTasks();
    }
  }

  static void _showMessage(String message) {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null) return;
    ThemedSnackbar.show(
      ctx,
      message: message,
      color: AppTheme.neonGreen,
    );
  }
}
