import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';

import 'browser_tab_identity.dart';

/// Encapsulates the WebViewController, navigation state, notifiers, and error
/// state of a browser tab.
class BrowserTabWebViewState {
  static final _log = Logger('browser_tab_webview_state');

  InAppWebViewController? controller;
  PullToRefreshController? pullToRefreshController;
  FindInteractionController? _findInteractionController;
  bool _findControllerInitFailed = false;

  final ValueNotifier<double> progressNotifier;
  final ValueNotifier<bool> loadingNotifier;
  final ValueNotifier<String> urlNotifier;

  bool canGoBack;
  bool canGoForward;
  bool hasCrashed;
  bool isTimedOut;
  bool isSuspended;
  bool hasError;
  String? errorDescription;
  bool hasAttemptedSilentReload;
  int lastRenderedProgress;

  bool _isDisposed = false;
  bool get isDisposed => _isDisposed;

  BrowserTabWebViewState({
    this.controller,
    this.pullToRefreshController,
    FindInteractionController? findController,
    double initialProgress = 0.0,
    bool initialLoading = false,
    String initialUrl = BrowserTabIdentity.canonicalBlankUrl,
    this.canGoBack = false,
    this.canGoForward = false,
    this.hasCrashed = false,
    this.isTimedOut = false,
    this.isSuspended = false,
    this.hasError = false,
    this.errorDescription,
    this.hasAttemptedSilentReload = false,
    this.lastRenderedProgress = 0,
  })  : progressNotifier = ValueNotifier<double>(initialProgress),
        loadingNotifier = ValueNotifier<bool>(initialLoading),
        urlNotifier = ValueNotifier<String>(
          BrowserTabIdentity.normalizeUrl(initialUrl),
        ),
        _findInteractionController = findController;

  FindInteractionController? get findInteractionController {
    if (_isDisposed || _findControllerInitFailed) return null;
    if (_findInteractionController == null) {
      try {
        _findInteractionController = FindInteractionController();
      } catch (e) {
        _findControllerInitFailed = true;
        _log.fine('[BrowserTabWebViewState] FindInteractionController skipped: $e');
      }
    }
    return _findInteractionController;
  }

  void resetFindController() {
    _findControllerInitFailed = false;
    _findInteractionController = null;
  }

  double get progress => progressNotifier.value;
  set progress(double val) {
    assert(!_isDisposed, 'Attempted to set progress on a disposed BrowserTab');
    if (_isDisposed) return;
    if (progressNotifier.value != val) {
      progressNotifier.value = val;
    }
  }

  bool get isLoading => loadingNotifier.value;
  set isLoading(bool val) {
    assert(!_isDisposed, 'Attempted to set isLoading on a disposed BrowserTab');
    if (_isDisposed) return;
    if (loadingNotifier.value != val) {
      loadingNotifier.value = val;
    }
  }

  void setUrl(String canonicalUrl) {
    assert(!_isDisposed, 'Attempted to set url on a disposed BrowserTab');
    if (_isDisposed) return;
    if (urlNotifier.value != canonicalUrl) {
      urlNotifier.value = canonicalUrl;
    }
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    controller = null;
    _findInteractionController = null;
    pullToRefreshController = null;
    progressNotifier.dispose();
    loadingNotifier.dispose();
    urlNotifier.dispose();
  }
}
