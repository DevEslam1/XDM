import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class BrowserTab {
  final String id;
  late final WebViewController controller;
  String url;
  String title;
  bool isIncognito;
  bool isLoading;
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
    double progress = 0.0,
    this.isHome = true,
    this.canGoBack = false,
    this.canGoForward = false,
  }) : progressNotifier = ValueNotifier<double>(progress);

  double get progress => progressNotifier.value;
  set progress(double val) => progressNotifier.value = val;
}
