import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';

enum TabOrigin { userDirect, adOrPopup, redirect }

class BrowserTab {
  static final _log = Logger('browser_tab');

  static const String canonicalBlankUrl = 'about:blank';

  final String id;
  InAppWebViewController? controller;
  String _url;
  String get url => _url;
  set url(String val) => updateUrl(val);

  String title;
  bool isIncognito;
  PullToRefreshController? pullToRefreshController;
  int lastRenderedProgress = 0;
  
  bool _isLoading;
  bool get isLoading => _isLoading;
  set isLoading(bool val) {
    _isLoading = val;
    // FIX(B2): Check _isDisposed before touching the notifier and guard the
    // value assignment against already-disposed notifiers.
    if (_isDisposed) return;
    try {
      if (loadingNotifier.value != val) {
        loadingNotifier.value = val;
      }
    } catch (e, st) {
      _log.warning('[browser_tab] loadingNotifier set failed', e, st);
    }
  }

  bool hasCrashed;
  bool isTimedOut;
  bool isSuspended;
  bool hasError;
  String? errorDescription;

  // FIX(D6): Set by the tab view after page load — whether the DOM contains a
  // <video> element. Used to show the PiP toolbar button.
  bool hasVideoElement = false;

  // FIX(U7): Full-page thumbnail captured after load, shown in the tab
  // switcher grid. Kept null for home/blank tabs.
  Uint8List? previewBytes;
  
  final ValueNotifier<double> progressNotifier;
  final ValueNotifier<bool> loadingNotifier;
  final ValueNotifier<String> urlNotifier;

  bool isHome;
  bool canGoBack;
  bool canGoForward;

  /// Milliseconds since epoch. Named `lastVisitedAtMs` for clarity.
  int lastVisitedAtMs = DateTime.now().millisecondsSinceEpoch;

  String? faviconUrl;
  
  // FIX-B2: Detach buffer copy to avoid keeping giant backing buffer in memory without corrupting image data
  Uint8List? _faviconBytes;
  Uint8List? get faviconBytes => _faviconBytes;
  set faviconBytes(Uint8List? bytes) {
    if (bytes != null && bytes.isNotEmpty) {
      if (bytes.length > 512 * 1024) {
        _faviconBytes = null;
      } else {
        _faviconBytes = Uint8List.fromList(bytes);
      }
    } else {
      _faviconBytes = null;
    }
  }

  int get faviconBytesSize => _faviconBytes?.length ?? 0;
  String? findQuery;
  TabOrigin origin;
  Color? themeColor;

  FindInteractionController? _findInteractionController;
  bool _findControllerInitFailed = false;
  FindInteractionController? get findInteractionController {
    if (_isDisposed || _findControllerInitFailed) return null;
    if (_findInteractionController == null) {
      try {
        _findInteractionController = FindInteractionController();
      } catch (e) {
        _findControllerInitFailed = true;
        _log.fine('[browser_tab] FindInteractionController skipped: $e');
      }
    }
    return _findInteractionController;
  }

  void resetFindController() {
    _findControllerInitFailed = false;
    _findInteractionController = null;
  }

  int savedScrollY = 0;
  String? tabGroupId;

  // FIX(B3): Per-tab crash-reload flag so silent reloads are attempted once
  // per crash rather than per State rebuild. Reset on every page-load start.
  bool hasAttemptedSilentReload = false;

  BrowserTab({
    required this.id,
    this.controller,
    required String url,
    this.title = '',
    this.isIncognito = false,
    bool isLoading = false,
    this.hasCrashed = false,
    this.isTimedOut = false,
    this.isSuspended = false,
    this.hasError = false,
    this.errorDescription,
    double progress = 0.0,
    bool? isHome,
    this.canGoBack = false,
    this.canGoForward = false,
    this.origin = TabOrigin.userDirect,
    int? createdAtMs,
    FindInteractionController? findController,
    this.savedScrollY = 0,
    this.tabGroupId,
    this.findQuery,
  })  : _url = (url.isEmpty || url == canonicalBlankUrl) ? canonicalBlankUrl : url,
        _isLoading = isLoading,
        isHome = isHome ?? (url.isEmpty || url == canonicalBlankUrl),
        createdAtMs = createdAtMs ?? DateTime.now().millisecondsSinceEpoch,
        progressNotifier = ValueNotifier<double>(progress),
        loadingNotifier = ValueNotifier<bool>(isLoading),
        urlNotifier = ValueNotifier<String>((url.isEmpty || url == canonicalBlankUrl) ? canonicalBlankUrl : url),
        _findInteractionController = findController;

  bool _isDisposed = false;
  bool get isDisposed => _isDisposed;

  double get progress => progressNotifier.value;

  set progress(double val) {
    // FIX(B2): Check _isDisposed before touching the notifier and guard the
    // value assignment against already-disposed notifiers.
    if (_isDisposed) return;
    try {
      progressNotifier.value = val;
    } catch (e, st) {
      _log.warning('[browser_tab] progressNotifier set failed', e, st);
    }
  }

  bool get isSecure => _url.toLowerCase().startsWith('https://');

  String? _cachedHost;
  final int createdAtMs;

  /// Cached host calculation for performance in interceptors
  String get host {
    if (_url.isEmpty || _url == canonicalBlankUrl) {
      _cachedHost = '';
      return '';
    }
    if (_cachedHost != null) return _cachedHost!;
    try {
      final parsed = Uri.tryParse(_url);
      _cachedHost = (parsed != null && parsed.hasAuthority) ? parsed.host.toLowerCase() : '';
    } catch (_) {
      _cachedHost = '';
    }
    return _cachedHost!;
  }

  void updateUrl(String newUrl) {
    final canonical = (newUrl.isEmpty || newUrl == canonicalBlankUrl)
        ? canonicalBlankUrl
        : newUrl;
    if (_url != canonical) {
      _url = canonical;
      _cachedHost = null;
      isHome = (canonical == canonicalBlankUrl);
      // FIX(B2): Check _isDisposed before touching the notifier and guard the
      // value assignment against already-disposed notifiers.
      if (_isDisposed) return;
      try {
        urlNotifier.value = canonical;
      } catch (e, st) {
        _log.warning('[browser_tab] urlNotifier set failed', e, st);
      }
    }
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
    if (title.trim().isNotEmpty && title.trim() != _url && title.trim() != canonicalBlankUrl) {
      return title.trim();
    }
    final d = domain;
    return d.isNotEmpty ? d : _url;
  }

  /// Backward-compatible alias for [lastVisitedAtMs].
  int get lastVisitedAt => lastVisitedAtMs;
  set lastVisitedAt(int value) => lastVisitedAtMs = value;

  void dispose() {
    // FIX(B2): Set _isDisposed FIRST so concurrent setters no-op, then detach
    // the controller, then dispose notifiers (guarded against double-dispose).
    if (_isDisposed) return;
    _isDisposed = true;
    controller = null;
    _findInteractionController = null;
    pullToRefreshController = null;
    try {
      progressNotifier.dispose();
      loadingNotifier.dispose();
      urlNotifier.dispose();
    } catch (e, st) {
      _log.warning('[browser_tab] notifier dispose failed', e, st);
    }
  }
}
