import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';

enum TabOrigin { userDirect, adOrPopup, redirect }

class BrowserTab {
  static final _log = Logger('browser_tab');

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

  /// Milliseconds since epoch. Named `lastVisitedAtMs` for clarity.
  int lastVisitedAtMs = DateTime.now().millisecondsSinceEpoch;

  String? faviconUrl;
  Uint8List? faviconBytes;
  String? findQuery;
  TabOrigin origin;
  Color? themeColor;

  FindInteractionController? _findInteractionController;

  FindInteractionController? get findInteractionController {
    if (_isDisposed) return null;
    if (_findInteractionController == null) {
      try {
        _findInteractionController = FindInteractionController();
      } catch (e) {
        _log.fine('[browser_tab] FindInteractionController skipped: $e');
      }
    }
    return _findInteractionController;
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

  bool get isSecure => url.toLowerCase().startsWith('https://');

  String get domain {
    try {
      var host = Uri.parse(url).host;
      if (host.startsWith('www.')) host = host.substring(4);
      return host;
    } catch (e, st) {
      _log.warning('[browser_tab] domain parse failed', e, st);
      return '';
    }
  }

  String get stripLabel {
    if (isHome) return 'Home';
    if (title.trim().isNotEmpty && title.trim() != url) return title.trim();
    final d = domain;
    return d.isNotEmpty ? d : url;
  }

  /// Backward-compatible alias for [lastVisitedAtMs].
  int get lastVisitedAt => lastVisitedAtMs;
  set lastVisitedAt(int value) => lastVisitedAtMs = value;

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    controller = null;
    pullToRefreshController = null;
    _findInteractionController = null;
    try {
      progressNotifier.dispose();
    } catch (e, st) {
      _log.warning('[browser_tab] progressNotifier dispose failed', e, st);
    }
  }
}