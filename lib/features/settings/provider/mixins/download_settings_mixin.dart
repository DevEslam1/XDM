// FIX-P2-03: Download settings mixin for SettingsProvider
import 'package:flutter/foundation.dart';

mixin DownloadSettingsMixin on ChangeNotifier {
  int _maxDownloads = 3;
  int get maxDownloads => _maxDownloads;
  set maxDownloads(int value) {
    if (_maxDownloads != value) {
      _maxDownloads = value;
      notifyListeners();
    }
  }

  int _speedLimitMb = 0;
  int get speedLimitMb => _speedLimitMb;
  set speedLimitMb(int value) {
    if (_speedLimitMb != value) {
      _speedLimitMb = value;
      notifyListeners();
    }
  }

  int _defaultThreadCount = 8;
  int get defaultThreadCount => _defaultThreadCount;
  set defaultThreadCount(int value) {
    if (_defaultThreadCount != value) {
      _defaultThreadCount = value;
      notifyListeners();
    }
  }

  String? _customDownloadPath;
  String? get customDownloadPath => _customDownloadPath;
  set customDownloadPath(String? value) {
    if (_customDownloadPath != value) {
      _customDownloadPath = value;
      notifyListeners();
    }
  }

  bool _categoryFolders = true;
  bool get categoryFolders => _categoryFolders;
  set categoryFolders(bool value) {
    if (_categoryFolders != value) {
      _categoryFolders = value;
      notifyListeners();
    }
  }
}
