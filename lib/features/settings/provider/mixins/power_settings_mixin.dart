// FIX-P2-03: Power settings mixin for SettingsProvider
import 'package:flutter/foundation.dart';

mixin PowerSettingsMixin on ChangeNotifier {
  bool _seedOnlyWhenCharging = false;
  bool get seedOnlyWhenCharging => _seedOnlyWhenCharging;
  set seedOnlyWhenCharging(bool value) {
    if (_seedOnlyWhenCharging != value) {
      _seedOnlyWhenCharging = value;
      notifyListeners();
    }
  }

  bool _seedOnlyOnWifi = true;
  bool get seedOnlyOnWifi => _seedOnlyOnWifi;
  set seedOnlyOnWifi(bool value) {
    if (_seedOnlyOnWifi != value) {
      _seedOnlyOnWifi = value;
      notifyListeners();
    }
  }
}
