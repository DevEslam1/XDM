import 'dart:io';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'background_service.dart';
import 'database_service.dart';

class DesktopTrayService with TrayListener {
  static final Logger _log = Logger('DesktopTrayService');
  static final DesktopTrayService instance = DesktopTrayService._();

  DesktopTrayService._();

  bool _initialized = false;
  VoidCallback? _onPauseAll;
  VoidCallback? _onResumeAll;

  Future<void> init({
    VoidCallback? onPauseAll,
    VoidCallback? onResumeAll,
  }) async {
    if (_initialized) return;
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;

    _onPauseAll = onPauseAll;
    _onResumeAll = onResumeAll;

    try {
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
      await windowManager.setMinimumSize(const Size(420, 320));

      await trayManager.setIcon('assets/app_icon/icon.png');
      await trayManager.setToolTip('XDM — Extreme Download Manager');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Show XDM'),
            MenuItem.separator(),
            MenuItem(key: 'pause_all', label: 'Pause All Downloads'),
            MenuItem(key: 'resume_all', label: 'Resume All Downloads'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: 'Quit XDM'),
          ],
        ),
      );
      trayManager.addListener(this);
      _initialized = true;
    } catch (e) {
      _log.warning('Desktop tray initialization warning: $e');
    }
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        windowManager.show();
        break;
      case 'pause_all':
        _onPauseAll?.call();
        break;
      case 'resume_all':
        _onResumeAll?.call();
        break;
      case 'quit':
        _exitApp();
        break;
    }
  }

  Future<void> _exitApp() async {
    try {
      await WakelockPlus.disable();
    } catch (e) {
      _log.fine('Wakelock disable skipped on exit: $e');
    }
    try {
      await BackgroundService.releaseWakeLock();
    } catch (e) {
      _log.fine('BackgroundService wake lock release skipped on exit: $e');
    }
    try {
      await DatabaseService.instance.dispose();
    } catch (e) {
      _log.fine('DatabaseService dispose skipped on exit: $e');
    }
    try {
      await trayManager.destroy();
    } catch (e) {
      _log.fine('trayManager destroy skipped on exit: $e');
    }
    try {
      await windowManager.destroy();
    } catch (e) {
      _log.fine('windowManager destroy skipped on exit: $e');
    }
  }

  Future<void> updateTooltip(
      {required int active, required String speed}) async {
    if (!_initialized) return;
    try {
      await trayManager.setToolTip('XDM — $active active ($speed)');
    } catch (e, st) {
      _log.warning('[DesktopTrayService] updateTooltip failed', e, st);
    }
  }
}
