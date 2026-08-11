import 'dart:io';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

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
      _initialized = true;
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
      await windowManager.setMinimumSize(const Size(420, 320));

      await trayManager.setIcon('assets/icon/app_icon.png');
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
        trayManager.destroy();
        windowManager.destroy();
        break;
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