import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:logging/logging.dart';
import '../app_theme.dart';
import '../../features/details/screens/details_screen.dart';
import '../../features/downloads/provider/download_provider.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../shared/widgets/themed_snackbar.dart';
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
///   `dmx://settings`                      → open settings
///   `dmx://add?url=<encoded-http(s)-url>` → show the add-download flow
///   `dmx://pause_all` / `dmx://resume_all` → toggle every download
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

    switch (uri.host.toLowerCase()) {
      case 'downloads':
        _showMessage('DMX Downloads');
        break;
      case 'download':
        final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
        if (id != null && id.isNotEmpty) _openTaskDetails(id);
        break;
      case 'settings':
        navigatorKey?.currentState?.push(
          MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
        );
        break;
      case 'add':
        final target = uri.queryParameters['url'];
        if (target != null && target.isNotEmpty) {
          _handleAddUrl(target);
        }
        break;
      case 'pause_all':
        _toggleAll(pause: true);
        break;
      case 'resume_all':
        _toggleAll(pause: false);
        break;
      default:
        _log.fine('Unhandled dmx:// route: ${uri.host}');
    }
  }

  static void _openTaskDetails(String taskId) {
    final navigator = navigatorKey?.currentState;
    if (navigator == null) return;
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => DetailsScreen(taskId: taskId)),
    );
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
