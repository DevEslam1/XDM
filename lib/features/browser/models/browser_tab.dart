import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class BrowserTab {
  final String id;
  late final WebViewController controller;
  String url;
  String title;
  bool isIncognito;
  bool isLoading;
  bool hasCrashed;
  bool isTimedOut;
  final ValueNotifier<double> progressNotifier;
  bool isHome;
  bool canGoBack;
  bool canGoForward;

  BrowserTab({
    required this.id,
    required this.controller,
    required this.url,
    required this.title,
    this.isIncognito = false,
    this.isLoading = false,
    this.hasCrashed = false,
    this.isTimedOut = false,
    double progress = 0.0,
    this.isHome = true,
    this.canGoBack = false,
    this.canGoForward = false,
  }) : progressNotifier = ValueNotifier<double>(progress);

  double get progress => progressNotifier.value;
  set progress(double val) => progressNotifier.value = val;

  /// True when the current URL is served over HTTPS.
  bool get isSecure => url.toLowerCase().startsWith('https://');

  /// Hostname without `www.` for tab-strip labels.
  String get domain {
    try {
      var host = Uri.parse(url).host;
      if (host.startsWith('www.')) host = host.substring(4);
      return host;
    } catch (_) {
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
    try {
      progressNotifier.dispose();
    } catch (_) {}
  }
}
