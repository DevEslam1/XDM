import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';

import 'browser_tab_identity.dart';
import 'browser_tab_ui_state.dart';
import 'browser_tab_webview_state.dart';

export 'browser_tab_identity.dart' show TabOrigin;
export 'browser_tab_ui_state.dart';
export 'browser_tab_webview_state.dart';

class BrowserTab {
  static final _log = Logger('browser_tab');
  static const String canonicalBlankUrl = BrowserTabIdentity.canonicalBlankUrl;

  final BrowserTabIdentity identity;
  final BrowserTabWebViewState webViewState;
  final BrowserTabUiState uiState;

  String _url;
  String? _cachedHost;
  bool isHome;

  BrowserTab({
    required String id,
    InAppWebViewController? controller,
    required String url,
    String title = '',
    bool isIncognito = false,
    bool isLoading = false,
    bool hasCrashed = false,
    bool isTimedOut = false,
    bool isSuspended = false,
    bool hasError = false,
    String? errorDescription,
    double progress = 0.0,
    bool? isHome,
    bool canGoBack = false,
    bool canGoForward = false,
    TabOrigin origin = TabOrigin.userDirect,
    int? createdAtMs,
    FindInteractionController? findController,
    int savedScrollY = 0,
    String? tabGroupId,
    String? findQuery,
    Uint8List? previewBytes,
    Uint8List? faviconBytes,
    String? faviconUrl,
    Color? themeColor,
  })  : _url = BrowserTabIdentity.normalizeUrl(url),
        identity = BrowserTabIdentity(
          id: id,
          createdAtMs: createdAtMs ?? DateTime.now().millisecondsSinceEpoch,
          isIncognito: isIncognito,
          origin: origin,
        ),
        webViewState = BrowserTabWebViewState(
          controller: controller,
          findController: findController,
          initialProgress: progress,
          initialLoading: isLoading,
          initialUrl: url,
          canGoBack: canGoBack,
          canGoForward: canGoForward,
          hasCrashed: hasCrashed,
          isTimedOut: isTimedOut,
          isSuspended: isSuspended,
          hasError: hasError,
          errorDescription: errorDescription,
        ),
        uiState = BrowserTabUiState(
          title: title,
          savedScrollY: savedScrollY,
          tabGroupId: tabGroupId,
          findQuery: findQuery,
          previewBytes: previewBytes,
          faviconBytes: faviconBytes,
          faviconUrl: faviconUrl,
          themeColor: themeColor,
        ),
        isHome = isHome ?? BrowserTabIdentity.isHomeUrl(url);

  // ── Identity Delegate Getters ─────────────────────────────────────────────
  String get id => identity.id;
  int get createdAtMs => identity.createdAtMs;
  bool get isIncognito => identity.isIncognito;
  TabOrigin get origin => identity.origin;
  set origin(TabOrigin val) => identity.origin = val;

  // ── WebViewState Delegate Getters/Setters ─────────────────────────────────
  InAppWebViewController? get controller => webViewState.controller;
  set controller(InAppWebViewController? val) => webViewState.controller = val;

  PullToRefreshController? get pullToRefreshController =>
      webViewState.pullToRefreshController;
  set pullToRefreshController(PullToRefreshController? val) =>
      webViewState.pullToRefreshController = val;

  FindInteractionController? get findInteractionController =>
      webViewState.findInteractionController;
  void resetFindController() => webViewState.resetFindController();

  ValueNotifier<double> get progressNotifier => webViewState.progressNotifier;
  ValueNotifier<bool> get loadingNotifier => webViewState.loadingNotifier;
  ValueNotifier<String> get urlNotifier => webViewState.urlNotifier;

  bool get isDisposed => webViewState.isDisposed;

  double get progress => webViewState.progress;
  set progress(double val) => webViewState.progress = val;

  bool get isLoading => webViewState.isLoading;
  set isLoading(bool val) => webViewState.isLoading = val;

  bool get canGoBack => webViewState.canGoBack;
  set canGoBack(bool val) {
    if (webViewState.isDisposed) return;
    webViewState.canGoBack = val;
  }

  bool get canGoForward => webViewState.canGoForward;
  set canGoForward(bool val) {
    if (webViewState.isDisposed) return;
    webViewState.canGoForward = val;
  }

  bool get hasCrashed => webViewState.hasCrashed;
  set hasCrashed(bool val) {
    if (webViewState.isDisposed) return;
    webViewState.hasCrashed = val;
  }

  bool get isTimedOut => webViewState.isTimedOut;
  set isTimedOut(bool val) {
    if (webViewState.isDisposed) return;
    webViewState.isTimedOut = val;
  }

  bool get isSuspended => webViewState.isSuspended;
  set isSuspended(bool val) {
    if (webViewState.isDisposed) return;
    webViewState.isSuspended = val;
  }

  bool get hasError => webViewState.hasError;
  set hasError(bool val) {
    if (webViewState.isDisposed) return;
    webViewState.hasError = val;
  }

  String? get errorDescription => webViewState.errorDescription;
  set errorDescription(String? val) {
    if (webViewState.isDisposed) return;
    webViewState.errorDescription = val;
  }

  bool get hasAttemptedSilentReload => webViewState.hasAttemptedSilentReload;
  set hasAttemptedSilentReload(bool val) {
    if (webViewState.isDisposed) return;
    webViewState.hasAttemptedSilentReload = val;
  }

  int get lastRenderedProgress => webViewState.lastRenderedProgress;
  set lastRenderedProgress(int val) {
    if (webViewState.isDisposed) return;
    webViewState.lastRenderedProgress = val;
  }

  // ── UiState Delegate Getters/Setters ──────────────────────────────────────
  String get title => uiState.title;
  set title(String val) => uiState.title = val;

  Color? get themeColor => uiState.themeColor;
  set themeColor(Color? val) => uiState.themeColor = val;

  String? get findQuery => uiState.findQuery;
  set findQuery(String? val) => uiState.findQuery = val;

  Uint8List? get previewBytes => uiState.previewBytes;
  set previewBytes(Uint8List? val) => uiState.previewBytes = val;

  int get savedScrollY => uiState.savedScrollY;
  set savedScrollY(int val) => uiState.savedScrollY = val;

  String? get tabGroupId => uiState.tabGroupId;
  set tabGroupId(String? val) => uiState.tabGroupId = val;

  bool get hasVideoElement => uiState.hasVideoElement;
  set hasVideoElement(bool val) => uiState.hasVideoElement = val;

  int get lastVisitedAtMs => uiState.lastVisitedAtMs;
  set lastVisitedAtMs(int val) => uiState.lastVisitedAtMs = val;

  int get lastVisitedAt => uiState.lastVisitedAtMs;
  set lastVisitedAt(int value) => uiState.lastVisitedAtMs = value;

  String? get faviconUrl => uiState.faviconUrl;
  set faviconUrl(String? val) => uiState.faviconUrl = val;

  Uint8List? get faviconBytes => uiState.faviconBytes;
  set faviconBytes(Uint8List? bytes) => uiState.faviconBytes = bytes;

  int get faviconBytesSize => uiState.faviconBytesSize;

  // ── URL & Navigation Helpers ──────────────────────────────────────────────
  String get url => _url;
  set url(String val) => updateUrl(val);

  bool get isSecure => _url.toLowerCase().startsWith('https://');

  String get host {
    if (_url.isEmpty || _url == canonicalBlankUrl) {
      _cachedHost = '';
      return '';
    }
    if (_cachedHost != null) return _cachedHost!;
    try {
      final parsed = Uri.tryParse(_url);
      _cachedHost = (parsed != null && parsed.hasAuthority)
          ? parsed.host.toLowerCase()
          : '';
    } catch (_) {
      _cachedHost = '';
    }
    return _cachedHost!;
  }

  String get domain {
    try {
      var h = host;
      if (h.startsWith('www.')) h = h.substring(4);
      return h;
    } catch (e, st) {
      _log.warning('[browser_tab] domain parse failed', e, st);
      return '';
    }
  }

  String get stripLabel {
    if (isHome) return 'Home';
    if (title.trim().isNotEmpty &&
        title.trim() != _url &&
        title.trim() != canonicalBlankUrl) {
      return title.trim();
    }
    final d = domain;
    return d.isNotEmpty ? d : _url;
  }

  void updateUrl(String newUrl) {
    final canonical = BrowserTabIdentity.normalizeUrl(newUrl);
    if (_url != canonical) {
      _url = canonical;
      _cachedHost = null;
      isHome = BrowserTabIdentity.isHomeUrl(canonical);
      webViewState.setUrl(canonical);
    }
  }

  void dispose() {
    webViewState.dispose();
  }
}
