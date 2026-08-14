// FIX-P2-03: UI settings mixin for SettingsProvider
import 'package:flutter/material.dart';

mixin UiSettingsMixin on ChangeNotifier {
  bool _enableGlow = true;
  bool get enableGlow => _enableGlow;
  set enableGlow(bool value) {
    if (_enableGlow != value) {
      _enableGlow = value;
      notifyListeners();
    }
  }

  double _gridOpacity = 0.5;
  double get gridOpacity => _gridOpacity;
  set gridOpacity(double value) {
    if (_gridOpacity != value) {
      _gridOpacity = value;
      notifyListeners();
    }
  }

  bool _classicUi = false;
  bool get classicUi => _classicUi;
  set classicUi(bool value) {
    if (_classicUi != value) {
      _classicUi = value;
      notifyListeners();
    }
  }

  bool _reduceVisuals = false;
  bool get reduceVisuals => _reduceVisuals;
  set reduceVisuals(bool value) {
    if (_reduceVisuals != value) {
      _reduceVisuals = value;
      notifyListeners();
    }
  }

  double _textScaleFactor = 1.0;
  double get textScaleFactor => _textScaleFactor;
  set textScaleFactor(double value) {
    if (_textScaleFactor != value) {
      _textScaleFactor = value;
      notifyListeners();
    }
  }
}
