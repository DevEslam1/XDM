import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsProvider extends ChangeNotifier {
  static const _autoStartKey = 'autoStart';
  static const _maxDownloadsKey = 'maxDownloads';
  static const _speedLimitKey = 'speedLimitMb';
  static const _enableGlowKey = 'enableGlow';
  static const _gridOpacityKey = 'gridOpacity';
  static const _soundNotificationKey = 'soundNotification';
  static const _vibrationKey = 'vibration';
  static const _wifiOnlyKey = 'wifiOnly';
  static const _languageCodeKey = 'languageCode';
  static const _isDarkModeKey = 'isDarkMode';
  static const _showOnboardingKey = 'showOnboarding';

  static const _biometricLockKey = 'biometricLock';
  static const _enableProxyKey = 'enableProxy';
  static const _proxyAddressKey = 'proxyAddress';
  static const _bypassSSLKey = 'bypassSSL';
  static const _reduceVisualsKey = 'reduceVisuals';
  static const _customUserAgentKey = 'customUserAgent';
  static const _cleanupDaysKey = 'cleanupDays';
  static const _categoryFoldersKey = 'categoryFolders';

  late final SharedPreferences _prefs;

  bool autoStart = true;
  int maxDownloads = 3;
  double speedLimitMb = 0.0;
  bool enableGlow = true;
  double gridOpacity = 12.0;
  bool soundNotification = true;
  bool vibration = false;
  bool wifiOnly = false;
  String languageCode = 'en';
  bool isDarkMode = true;
  bool showOnboarding = true;

  bool biometricLock = false;
  bool enableProxy = false;
  String proxyAddress = '';
  bool bypassSSL = false;
  bool reduceVisuals = false;
  String customUserAgent = '';
  int cleanupDays = 0;
  bool categoryFolders = false;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    autoStart = _prefs.getBool(_autoStartKey) ?? autoStart;
    maxDownloads = _prefs.getInt(_maxDownloadsKey) ?? maxDownloads;
    speedLimitMb = _prefs.getDouble(_speedLimitKey) ?? speedLimitMb;
    enableGlow = _prefs.getBool(_enableGlowKey) ?? enableGlow;
    gridOpacity = _prefs.getDouble(_gridOpacityKey) ?? gridOpacity;
    soundNotification =
        _prefs.getBool(_soundNotificationKey) ?? soundNotification;
    vibration = _prefs.getBool(_vibrationKey) ?? vibration;
    wifiOnly = _prefs.getBool(_wifiOnlyKey) ?? wifiOnly;
    languageCode = _prefs.getString(_languageCodeKey) ?? languageCode;
    isDarkMode = _prefs.getBool(_isDarkModeKey) ?? isDarkMode;
    showOnboarding = _prefs.getBool(_showOnboardingKey) ?? showOnboarding;

    biometricLock = _prefs.getBool(_biometricLockKey) ?? biometricLock;
    enableProxy = _prefs.getBool(_enableProxyKey) ?? enableProxy;
    proxyAddress = _prefs.getString(_proxyAddressKey) ?? proxyAddress;
    bypassSSL = _prefs.getBool(_bypassSSLKey) ?? bypassSSL;
    reduceVisuals = _prefs.getBool(_reduceVisualsKey) ?? reduceVisuals;
    customUserAgent = _prefs.getString(_customUserAgentKey) ?? customUserAgent;
    cleanupDays = _prefs.getInt(_cleanupDaysKey) ?? cleanupDays;
    categoryFolders = _prefs.getBool(_categoryFoldersKey) ?? categoryFolders;
  }

  int get speedLimitBytesPerSecond => (speedLimitMb * 1024 * 1024).round();

  Future<void> setAutoStart(bool value) async {
    autoStart = value;
    await _prefs.setBool(_autoStartKey, value);
    notifyListeners();
  }

  Future<void> setMaxDownloads(int value) async {
    maxDownloads = value;
    await _prefs.setInt(_maxDownloadsKey, value);
    notifyListeners();
  }

  Future<void> setSpeedLimit(double value) async {
    speedLimitMb = value;
    await _prefs.setDouble(_speedLimitKey, value);
    notifyListeners();
  }

  Future<void> setEnableGlow(bool value) async {
    enableGlow = value;
    await _prefs.setBool(_enableGlowKey, value);
    notifyListeners();
  }

  Future<void> setGridOpacity(double value) async {
    gridOpacity = value;
    await _prefs.setDouble(_gridOpacityKey, value);
    notifyListeners();
  }

  Future<void> setSoundNotification(bool value) async {
    soundNotification = value;
    await _prefs.setBool(_soundNotificationKey, value);
    notifyListeners();
  }

  Future<void> setVibration(bool value) async {
    vibration = value;
    await _prefs.setBool(_vibrationKey, value);
    notifyListeners();
  }

  Future<void> setWifiOnly(bool value) async {
    wifiOnly = value;
    await _prefs.setBool(_wifiOnlyKey, value);
    notifyListeners();
  }

  Future<void> setLanguageCode(String value) async {
    languageCode = value;
    await _prefs.setString(_languageCodeKey, value);
    notifyListeners();
  }

  Future<void> setIsDarkMode(bool value) async {
    isDarkMode = value;
    await _prefs.setBool(_isDarkModeKey, value);
    notifyListeners();
  }

  Future<void> setShowOnboarding(bool value) async {
    showOnboarding = value;
    await _prefs.setBool(_showOnboardingKey, value);
    notifyListeners();
  }

  Future<void> setBiometricLock(bool value) async {
    biometricLock = value;
    await _prefs.setBool(_biometricLockKey, value);
    notifyListeners();
  }

  Future<void> setEnableProxy(bool value) async {
    enableProxy = value;
    await _prefs.setBool(_enableProxyKey, value);
    notifyListeners();
  }

  Future<void> setProxyAddress(String value) async {
    proxyAddress = value;
    await _prefs.setString(_proxyAddressKey, value);
    notifyListeners();
  }

  Future<void> setCustomUserAgent(String value) async {
    customUserAgent = value;
    await _prefs.setString(_customUserAgentKey, value);
    notifyListeners();
  }

  Future<void> setCleanupDays(int value) async {
    cleanupDays = value;
    await _prefs.setInt(_cleanupDaysKey, value);
    notifyListeners();
  }

  Future<void> setCategoryFolders(bool value) async {
    categoryFolders = value;
    await _prefs.setBool(_categoryFoldersKey, value);
    notifyListeners();
  }

  Future<void> setBypassSSL(bool value) async {
    bypassSSL = value;
    await _prefs.setBool(_bypassSSLKey, value);
    notifyListeners();
  }

  Future<void> setReduceVisuals(bool value) async {
    reduceVisuals = value;
    await _prefs.setBool(_reduceVisualsKey, value);
    notifyListeners();
  }
}
