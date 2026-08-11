import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import '../models/browser_tab.dart';

/// Manages inactivity timer, background hibernation, memory pressure, and
/// app lifecycle media pausing for the XDM browser feature.
class InactivityWatchdog {
  static final _log = Logger('InactivityWatchdog');

  static const Duration inactivityDuration = Duration(minutes: 5);

  Timer? _inactivityTimer;
  bool _isHibernating = false;

  bool get isHibernating => _isHibernating;

  /// Resets the 5-minute inactivity timer.
  void resetTimer({
    required bool isMounted,
    required VoidCallback onTimeout,
  }) {
    _inactivityTimer?.cancel();
    if (_isHibernating) {
      _isHibernating = false;
      _log.warning(
          '[BrowserWatchdog] Browser active — resuming inactivity watchdog.');
    }
    if (!isMounted) return;
    _inactivityTimer = Timer(inactivityDuration, () {
      onTimeout();
    });
  }

  /// Pauses video/audio elements on [tab].
  void pauseTabMedia(BrowserTab tab) {
    if (!tab.isHome) {
      try {
        tab.controller
            ?.evaluateJavascript(
              source:
                  "try { document.querySelectorAll('video,audio').forEach(function(m){m.pause();}); } catch(e){}",
            )
            .catchError((_) => null);
      } catch (e) {
        _log.warning('[Browser] Pause media error: $e');
      }
    }
  }

  /// Executes background hibernation cleanup on inactivity timeout or memory pressure.
  void hibernate({
    required bool isMounted,
    required List<BrowserTab> tabs,
    required int currentTabIndex,
    required VoidCallback cancelScanTimers,
    required VoidCallback saveTabs,
  }) {
    if (!isMounted || _isHibernating) return;
    _isHibernating = true;
    _log.warning(
      '[BrowserWatchdog] 5 minutes of inactivity reached. Cleaning up browser services & background tab resources to save RAM and battery.',
    );

    for (final tab in tabs) {
      pauseTabMedia(tab);
    }

    for (var i = 0; i < tabs.length; i++) {
      if (i != currentTabIndex) {
        final tab = tabs[i];
        if (!tab.isHome) {
          try {
            tab.controller
                ?.evaluateJavascript(
                    source: 'try { window.stop(); } catch(e){}')
                .catchError((_) => null);
          } catch (_) {}
        }
      }
    }

    cancelScanTimers();
    saveTabs();
  }

  /// Handles AppLifecycleState transitions (resumed vs paused/inactive).
  void handleAppLifecycleState({
    required AppLifecycleState state,
    required List<BrowserTab> tabs,
    required VoidCallback resetInactivityTimer,
  }) {
    if (state == AppLifecycleState.resumed) {
      resetInactivityTimer();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      for (final tab in tabs) {
        pauseTabMedia(tab);
      }
    }
  }

  void dispose() {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
  }
}
