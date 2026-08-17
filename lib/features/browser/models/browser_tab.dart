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
    if (!_isDisposed && loadingNotifier.value != val) {
      loadingNotifier.value = val;
    }
  }

  bool hasCrashed;
  bool isTimedOut;
  bool isSuspended;
  bool hasError;
  String? errorDescription;
  
  final ValueNotifier<double> progressNotifier;
  final ValueNotifier<bool> loadingNotifier;
  final ValueNotifier<String> urlNotifier;

  bool isHome;
  bool canGoBack;
  bool canGoForward;

  /// Milliseconds since epoch. Named `lastVisitedAtMs` for clarity.
  int lastVisitedAtMs = DateTime.now().millisecondsSinceEpoch;

  String? faviconUrl;
  
  // FIX-B2: Detach sublist buffer to avoid keeping giant backing buffer in memory
  Uint8List? _faviconBytes;
  Uint8List? get faviconBytes => _faviconBytes;
  set faviconBytes(Uint8List? bytes) {
    if (bytes != null && bytes.length > 10240) {
      _faviconBytes = Uint8List.fromList(bytes.sublist(0, 10240));
    } else {
      _faviconBytes = bytes;
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
    if (_isDisposed) return;
    progressNotifier.value = val;
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
      if (!_isDisposed) {
        urlNotifier.value = canonical;
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
