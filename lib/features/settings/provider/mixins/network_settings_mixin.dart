// FIX-P2-03: Network settings mixin for SettingsProvider
import 'package:flutter/foundation.dart';

mixin NetworkSettingsMixin on ChangeNotifier {
  bool _wifiOnly = false;
  bool get wifiOnly => _wifiOnly;
  set wifiOnly(bool value) {
    if (_wifiOnly != value) {
      _wifiOnly = value;
      notifyListeners();
    }
  }

  bool _httpsOnly = false;
  bool get httpsOnly => _httpsOnly;
  set httpsOnly(bool value) {
    if (_httpsOnly != value) {
      _httpsOnly = value;
      notifyListeners();
    }
  }

  String? _customUserAgent;
  String? get customUserAgent => _customUserAgent;
  set customUserAgent(String? value) {
    if (_customUserAgent != value) {
      _customUserAgent = value;
      notifyListeners();
    }
  }

  bool _bandwidthScheduleEnabled = false;
  bool get bandwidthScheduleEnabled => _bandwidthScheduleEnabled;
  set bandwidthScheduleEnabled(bool value) {
    if (_bandwidthScheduleEnabled != value) {
      _bandwidthScheduleEnabled = value;
      notifyListeners();
    }
  }
}
