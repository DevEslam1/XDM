import 'dart:async';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../data/browser_preferences_repository.dart';
import '../models/browser_tab.dart';
import '../widgets/browser_download_sheet.dart';
import 'download_interceptor.dart';
import 'media_sniffer.dart';

/// Coordinates media stream sniffing, URL download interception, and download prompts.
class BrowserDownloadCoordinator extends ChangeNotifier {
  static final _log = Logger('BrowserDownloadCoordinator');

  final DownloadProvider downloadProvider;
  final SettingsProvider settingsProvider;
  final BrowserPreferencesRepository prefsRepo;

  late final MediaSniffer mediaSniffer;
  late final DownloadInterceptor downloadInterceptor;

  bool _isSnifferEnabled = true;
  bool get isSnifferEnabled => _isSnifferEnabled;
  bool _isDisposed = false;

  BrowserDownloadCoordinator({
    required this.downloadProvider,
    required this.settingsProvider,
    required this.prefsRepo,
    required BrowserTab? Function() getActiveTab,
    required bool Function(BrowserTab) containsTab,
    required VoidCallback onStateChanged,
  }) {
    mediaSniffer = MediaSniffer(
      isActive: () => !_isDisposed,
      containsTab: containsTab,
      isSnifferEnabled: () => _isSnifferEnabled,
      onStateChanged: () {
        notifyListeners();
        onStateChanged();
      },
    );

    downloadInterceptor = DownloadInterceptor(
      resolveDownloadProvider: () => downloadProvider,
      resolveActiveTab: getActiveTab,
    );

    _init();
  }

  Future<void> _init() async {
    try {
      _isSnifferEnabled = await prefsRepo.getSnifferEnabled();
      notifyListeners();
    } catch (e, st) {
      _log.warning('Sniffer pref init error', e, st);
    }
  }

  Future<void> setSnifferEnabled(bool value) async {
    if (_isSnifferEnabled == value) return;
    _isSnifferEnabled = value;
    await prefsRepo.setSnifferEnabled(value);
    notifyListeners();
  }

  void promptDownload(
    BuildContext context, {
    required String url,
    String? suggestedFilename,
  }) {
    BrowserDownloadSheet.show(
      context,
      url,
      suggestedName: suggestedFilename,
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    mediaSniffer.dispose();
    downloadInterceptor.dispose();
    super.dispose();
  }
}
