import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';

/// Describes how a [BrowserTab] was originally created.
///
/// - [userDirect]  – opened by an explicit user action (typing a URL, tapping
///                   a home shortcut, long-pressing "Open in new tab", etc.)
/// - [adOrPopup]   – opened automatically by an ad-classified navigation or a
///                   JS popup (window.open / target=_blank intercepted as ad).
/// - [redirect]    – opened by the browser's own redirect-chain follower when
///                   it resolved an ad redirect to a legitimate file host.
enum TabOrigin { userDirect, adOrPopup, redirect }

class BrowserTab {
  final String id;
  InAppWebViewController? controller;
  String url;
  String title;
  bool isIncognito;
  PullToRefreshController? pullToRefreshController;
  int lastRenderedProgress = 0;
  bool isLoading;
  bool hasCrashed;
  bool isTimedOut;
  bool isSuspended;
  bool hasError;
  String? errorDescription;
  final ValueNotifier<double> progressNotifier;
  bool isHome;
  bool canGoBack;
  bool canGoForward;
  int lastVisitedAt = DateTime.now().millisecondsSinceEpoch;
  String? faviconUrl;

  /// Decoded favicon bytes for the tab (shown in the tab switcher / strip).
  /// Populated by the browser screen after a page load.
  Uint8List? faviconBytes;

  /// The last find-in-page query entered for this tab. Restored when the
  /// find panel is reopened for the tab.
  String? findQuery;

  /// How this tab was opened. Used for back-button auto-close and ad-tab management.
  TabOrigin origin;

  /// Dynamic theme color extracted from page meta tag or favicon.
  Color? themeColor;

  /// Controls the native find-in-page bar for this tab.
  FindInteractionController? _findInteractionController;

  FindInteractionController? get findInteractionController {
    if (_findInteractionController != null) return _findInteractionController;
    try {
      _findInteractionController = FindInteractionController();
    } catch (_) {
      // In pure Dart unit test environments where InAppWebViewPlatform is uninitialized
      return null;
    }
    return _findInteractionController;
  }

  set findInteractionController(FindInteractionController? ctrl) {
    _findInteractionController = ctrl;
  }

  BrowserTab({
    required this.id,
    this.controller,
    required this.url,
    required this.title,
    this.isIncognito = false,
    this.isLoading = false,
    this.hasCrashed = false,
    this.isTimedOut = false,
    this.isSuspended = false,
    this.hasError = false,
    this.errorDescription,
    double progress = 0.0,
    this.isHome = true,
    this.canGoBack = false,
    this.canGoForward = false,
    this.origin = TabOrigin.userDirect,
    FindInteractionController? findController,
  })  : progressNotifier = ValueNotifier<double>(progress),
        _findInteractionController = findController;

  bool _isDisposed = false;
  bool get isDisposed => _isDisposed;

  double get progress => progressNotifier.value;
  set progress(double val) {
    if (_isDisposed) return;
    progressNotifier.value = val;
  }

  /// True when the current URL is served over HTTPS.
  bool get isSecure => url.toLowerCase().startsWith('https://');

  /// Hostname without `www.` for tab-strip labels.
  String get domain {
    try {
      var host = Uri.parse(url).host;
      if (host.startsWith('www.')) host = host.substring(4);
      return host;
    } catch (e, st) {
      Logger('browser_tab').warning('[browser_tab] operation failed', e, st);
      return '';
    }
  }

  /// Short label for the tab strip: prefers the page title, falls back to domain.
  String get stripLabel {
    if (isHome) return 'Home';
    if (title.trim().isNotEmpty && title.trim() != url) return title.trim();
    final d = domain;
    return d.isNotEmpty ? d : url;
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    try {
      // Defer disposing progressNotifier to the next frame to prevent
      // "A ValueNotifier was used after being disposed" if it is currently
      // being listened to by a ValueListenableBuilder in the active tree.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        progressNotifier.dispose();
      });
      // NOTE: pullToRefreshController is owned and disposed synchronously
      // by _InAppWebViewState. Do NOT call prc.dispose() here — the widget
      // framework already handles it and a second call throws
      // "AndroidPullToRefreshController was used after being disposed".
      pullToRefreshController = null;
    } catch (e, st) {
      Logger('browser_tab').warning('[browser_tab] operation failed', e, st);
    }
  }
}
