import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  static const _themeModeKey = 'themeMode';
  static const _showOnboardingKey = 'showOnboarding';
  static const _classicUiKey = 'classicUi';


  static const _enableProxyKey = 'enableProxy';
  static const _proxyAddressKey = 'proxyAddress';
  static const _bypassSSLKey = 'bypassSSL_v2'; // v2: default false
  static const _reduceVisualsKey = 'reduceVisuals';
  static const _customUserAgentKey = 'customUserAgent';
  static const _cleanupDaysKey = 'cleanupDays';
  static const _categoryFoldersKey = 'categoryFolders';
  static const _globalTorrentSeedingKey = 'globalTorrentSeeding';
  static const _globalTorrentSeedingLimitedKey = 'globalTorrentSeedingLimited';
  static const _globalTorrentSeedingLimitKbpsKey = 'globalTorrentSeedingLimitKbps';
  static const _enableDhtKey = 'enableDht';
  static const _enableUpnpKey = 'enableUpnp';
  static const _forceEncryptKey = 'forceEncrypt';
  static const _torrentConnectionsLimitKey = 'torrentConnectionsLimit';
  static const _defaultThreadCountKey = 'defaultThreadCount';
  static const _customDownloadPathKey = 'customDownloadPath';
  static const _incognitoEnabledKey = 'incognitoEnabled';
  static const _desktopModeKey = 'desktopMode';
  static const _adBlockerEnabledKey = 'adBlockerEnabled';
  static const _pinchToZoomKey = 'pinchToZoom';
  static const _batterySaverModeKey = 'batterySaverMode';
  static const _saveBrowserHistoryKey = 'saveBrowserHistory';
  static const _notificationsEnabledKey = 'notificationsEnabled';
  static const _proxyHostKey = 'proxyHost';
  static const _proxyPortKey = 'proxyPort';
  static const _proxyUsernameKey = 'proxyUsername';
  static const _proxyPasswordKey = 'proxyPassword';
  static const _autoRetryEnabledKey = 'autoRetryEnabled';
  static const _maxRetriesKey = 'maxRetries';
  static const _retryDelaySecondsKey = 'retryDelaySeconds';
  static const _searchEngineKey = 'searchEngine';
  static const _useRemoteBackendKey = 'use_remote_backend';

  static const _backendUrlKey = 'backend_url';
  static const _backendTokenKey = 'backend_token';
  static const _sendBrowserCookiesToBackendKey = 'send_browser_cookies_to_backend';


  late final SharedPreferences _prefs;
  final _secureStorage = const FlutterSecureStorage();

  bool autoStart = true;
  String? customDownloadPath;
  int _maxDownloads = 3;
  int get maxDownloads => batterySaverMode ? 1 : _maxDownloads;
  double speedLimitMb = 0.0;
  bool enableGlow = true;
  double gridOpacity = 12.0;
  bool soundNotification = true;
  bool vibration = false;
  bool wifiOnly = false;
  String languageCode = 'en';
  bool _isDarkMode = true;
  bool get isDarkMode {
    if (themeMode == 'system') {
      try {
        return WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
      } catch (_) {
        return _isDarkMode;
      }
    }
    return themeMode == 'dark';
  }
  set isDarkMode(bool value) {
    _isDarkMode = value;
    _prefs.setBool(_isDarkModeKey, value);
    notifyListeners();
  }
  String themeMode = 'system';
  bool showOnboarding = true;
  bool _classicUi = true;
  bool get classicUi => batterySaverMode ? true : _classicUi;
  bool batterySaverMode = false;


  bool enableProxy = false;
  String proxyAddress = '';
  bool bypassSSL = false;
  bool reduceVisuals = false;
  String customUserAgent = '';
  int cleanupDays = 0;
  bool categoryFolders = false;

  String backendUrl = '';
  String backendToken = '';
  bool sendBrowserCookiesToBackend = false;

  // Torrent Seeding settings
  bool globalTorrentSeeding = true;
  bool globalTorrentSeedingLimited = false;
  int globalTorrentSeedingLimitKbps = 500;

  // Advanced Torrent settings
  bool enableDht = true;
  bool enableUpnp = true;
  bool forceEncrypt = false;
  int torrentConnectionsLimit = 200;

  int get configuredMaxDownloads => _maxDownloads;
  bool get configuredClassicUi => _classicUi;
  int get configuredDefaultThreadCount => _defaultThreadCount;

  // Issue 5 Fix: Effective getters for battery saver mode overrides
  int get effectiveMaxDownloads => batterySaverMode ? 1 : _maxDownloads;
  bool get effectiveClassicUi => batterySaverMode ? true : _classicUi;
  int get effectiveDefaultThreadCount => batterySaverMode ? 2 : _defaultThreadCount;

  int _defaultThreadCount = 5;
  int get defaultThreadCount => batterySaverMode ? 2 : _defaultThreadCount;

  // Browser settings
  bool incognitoEnabled = false;
  bool desktopMode = false;
  bool adBlockerEnabled = true;
  bool pinchToZoom = true;
  bool saveBrowserHistory = true;

  bool notificationsEnabled = true;
  String proxyHost = '';
  int proxyPort = 8080;
  String proxyUsername = '';
  String proxyPassword = '';
  bool autoRetryEnabled = true;
  int maxRetries = 3;
  int retryDelaySeconds = 3;
  String searchEngine = 'Google';
  bool useRemoteBackend = true;


  void _onPlatformBrightnessChanged() {
    if (themeMode == 'system') {
      final newDark = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
      if (newDark != _isDarkMode) {
        _isDarkMode = newDark;
        notifyListeners();
      }
    }
  }

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged = _onPlatformBrightnessChanged;
    autoStart = _prefs.getBool(_autoStartKey) ?? autoStart;
    _maxDownloads = _prefs.getInt(_maxDownloadsKey) ?? _maxDownloads;
    if (![1, 2, 3, 5, 8].contains(_maxDownloads)) _maxDownloads = 3;
    speedLimitMb = _prefs.getDouble(_speedLimitKey) ?? speedLimitMb;
    enableGlow = _prefs.getBool(_enableGlowKey) ?? enableGlow;
    gridOpacity = _prefs.getDouble(_gridOpacityKey) ?? gridOpacity;
    soundNotification =
        _prefs.getBool(_soundNotificationKey) ?? soundNotification;
    vibration = _prefs.getBool(_vibrationKey) ?? vibration;
    wifiOnly = _prefs.getBool(_wifiOnlyKey) ?? wifiOnly;
    languageCode = _prefs.getString(_languageCodeKey) ?? languageCode;
    themeMode = _prefs.getString(_themeModeKey) ?? 'system';
    _isDarkMode = _prefs.getBool(_isDarkModeKey) ?? isDarkMode;
    showOnboarding = _prefs.getBool(_showOnboardingKey) ?? showOnboarding;
    _classicUi = _prefs.getBool(_classicUiKey) ?? _classicUi;
    batterySaverMode = _prefs.getBool(_batterySaverModeKey) ?? batterySaverMode;


    enableProxy = _prefs.getBool(_enableProxyKey) ?? enableProxy;
    proxyAddress = _prefs.getString(_proxyAddressKey) ?? proxyAddress;
    bypassSSL = _prefs.getBool(_bypassSSLKey) ?? bypassSSL;
    reduceVisuals = _prefs.getBool(_reduceVisualsKey) ?? reduceVisuals;
    customUserAgent = _prefs.getString(_customUserAgentKey) ?? customUserAgent;
    cleanupDays = _prefs.getInt(_cleanupDaysKey) ?? cleanupDays;
    if (![0, 7, 30].contains(cleanupDays)) cleanupDays = 0;
    categoryFolders = _prefs.getBool(_categoryFoldersKey) ?? categoryFolders;

    backendUrl = _prefs.getString(_backendUrlKey) ?? backendUrl;
    backendToken = await _secureStorage.read(key: _backendTokenKey) ?? '';
    sendBrowserCookiesToBackend = _prefs.getBool(_sendBrowserCookiesToBackendKey) ?? sendBrowserCookiesToBackend;

    globalTorrentSeeding = _prefs.getBool(_globalTorrentSeedingKey) ?? globalTorrentSeeding;
    globalTorrentSeedingLimited = _prefs.getBool(_globalTorrentSeedingLimitedKey) ?? globalTorrentSeedingLimited;
    globalTorrentSeedingLimitKbps = _prefs.getInt(_globalTorrentSeedingLimitKbpsKey) ?? globalTorrentSeedingLimitKbps;
    enableDht = _prefs.getBool(_enableDhtKey) ?? enableDht;
    enableUpnp = _prefs.getBool(_enableUpnpKey) ?? enableUpnp;
    forceEncrypt = _prefs.getBool(_forceEncryptKey) ?? forceEncrypt;
    torrentConnectionsLimit = (_prefs.getInt(_torrentConnectionsLimitKey) ?? torrentConnectionsLimit).clamp(10, 1000);
    _defaultThreadCount = _prefs.getInt(_defaultThreadCountKey) ?? _defaultThreadCount;
    if (![1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 16].contains(_defaultThreadCount)) _defaultThreadCount = 5;
    customDownloadPath = _prefs.getString(_customDownloadPathKey);
    incognitoEnabled = _prefs.getBool(_incognitoEnabledKey) ?? incognitoEnabled;
    desktopMode = _prefs.getBool(_desktopModeKey) ?? desktopMode;
    adBlockerEnabled = _prefs.getBool(_adBlockerEnabledKey) ?? adBlockerEnabled;
    pinchToZoom = _prefs.getBool(_pinchToZoomKey) ?? pinchToZoom;
    saveBrowserHistory = _prefs.getBool(_saveBrowserHistoryKey) ?? saveBrowserHistory;
    notificationsEnabled = _prefs.getBool(_notificationsEnabledKey) ?? true;
    proxyHost = _prefs.getString(_proxyHostKey) ?? '';
    proxyPort = _prefs.getInt(_proxyPortKey) ?? 8080;
    proxyUsername = _prefs.getString(_proxyUsernameKey) ?? '';
    
    proxyPassword = await _secureStorage.read(key: _proxyPasswordKey) ?? '';
    final legacyPassword = _prefs.getString(_proxyPasswordKey);
    if (legacyPassword != null && legacyPassword.isNotEmpty && proxyPassword.isEmpty) {
      proxyPassword = legacyPassword;
      await _secureStorage.write(key: _proxyPasswordKey, value: proxyPassword);
      await _prefs.remove(_proxyPasswordKey);
    }

    autoRetryEnabled = _prefs.getBool(_autoRetryEnabledKey) ?? autoRetryEnabled;
    maxRetries = _prefs.getInt(_maxRetriesKey) ?? maxRetries;
    if (![1, 2, 3, 5, 10].contains(maxRetries)) maxRetries = 3;
    retryDelaySeconds = _prefs.getInt(_retryDelaySecondsKey) ?? retryDelaySeconds;
    if (![5, 10, 30, 60].contains(retryDelaySeconds)) retryDelaySeconds = 10;
    searchEngine = _prefs.getString(_searchEngineKey) ?? searchEngine;
    useRemoteBackend = _prefs.getBool(_useRemoteBackendKey) ?? true;
  }


  int get speedLimitBytesPerSecond => (speedLimitMb * 1024 * 1024).round();

  Future<void> setAutoStart(bool value) async {
    autoStart = value;
    await _prefs.setBool(_autoStartKey, value);
    notifyListeners();
  }

  Future<void> setMaxDownloads(int value) async {
    _maxDownloads = value;
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

  Future<void> setClassicUi(bool value) async {
    _classicUi = value;
    await _prefs.setBool(_classicUiKey, value);
    notifyListeners();
  }



  Future<void> setUseRemoteBackend(bool value) async {
    useRemoteBackend = value;
    await _prefs.setBool(_useRemoteBackendKey, value);
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

  Future<void> setGlobalTorrentSeeding(bool value) async {
    globalTorrentSeeding = value;
    await _prefs.setBool(_globalTorrentSeedingKey, value);
    notifyListeners();
  }

  Future<void> setGlobalTorrentSeedingLimited(bool value) async {
    globalTorrentSeedingLimited = value;
    await _prefs.setBool(_globalTorrentSeedingLimitedKey, value);
    notifyListeners();
  }

  Future<void> setGlobalTorrentSeedingLimitKbps(int value) async {
    globalTorrentSeedingLimitKbps = value;
    await _prefs.setInt(_globalTorrentSeedingLimitKbpsKey, value);
    notifyListeners();
  }

  Future<void> setEnableDht(bool value) async {
    enableDht = value;
    await _prefs.setBool(_enableDhtKey, value);
    notifyListeners();
  }

  Future<void> setEnableUpnp(bool value) async {
    enableUpnp = value;
    await _prefs.setBool(_enableUpnpKey, value);
    notifyListeners();
  }

  Future<void> setForceEncrypt(bool value) async {
    forceEncrypt = value;
    await _prefs.setBool(_forceEncryptKey, value);
    notifyListeners();
  }

  Future<void> setTorrentConnectionsLimit(int value) async {
    torrentConnectionsLimit = value;
    await _prefs.setInt(_torrentConnectionsLimitKey, value);
    notifyListeners();
  }

  Future<void> setDefaultThreadCount(int value) async {
    _defaultThreadCount = value;
    await _prefs.setInt(_defaultThreadCountKey, value);
    notifyListeners();
  }

  Future<void> setBatterySaverMode(bool value) async {
    batterySaverMode = value;
    await _prefs.setBool(_batterySaverModeKey, value);
    notifyListeners();
  }

  Future<void> setCustomDownloadPath(String? value) async {
    customDownloadPath = value;
    if (value == null) {
      await _prefs.remove(_customDownloadPathKey);
    } else {
      await _prefs.setString(_customDownloadPathKey, value);
    }
    notifyListeners();
  }

  Future<void> setIncognitoEnabled(bool value) async {
    incognitoEnabled = value;
    await _prefs.setBool(_incognitoEnabledKey, value);
    notifyListeners();
  }

  Future<void> setDesktopMode(bool value) async {
    desktopMode = value;
    await _prefs.setBool(_desktopModeKey, value);
    notifyListeners();
  }

  Future<void> setAdBlockerEnabled(bool value) async {
    adBlockerEnabled = value;
    await _prefs.setBool(_adBlockerEnabledKey, value);
    notifyListeners();
  }

  Future<void> setPinchToZoom(bool value) async {
    pinchToZoom = value;
    await _prefs.setBool(_pinchToZoomKey, value);
    notifyListeners();
  }

  Future<void> setSaveBrowserHistory(bool value) async {
    saveBrowserHistory = value;
    await _prefs.setBool(_saveBrowserHistoryKey, value);
    notifyListeners();
  }

  ThemeMode get currentThemeMode {
    switch (themeMode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setAutoRetryEnabled(bool value) async {
    autoRetryEnabled = value;
    await _prefs.setBool(_autoRetryEnabledKey, value);
    notifyListeners();
  }

  Future<void> setMaxRetries(int value) async {
    maxRetries = value;
    await _prefs.setInt(_maxRetriesKey, value);
    notifyListeners();
  }

  Future<void> setRetryDelaySeconds(int value) async {
    retryDelaySeconds = value;
    await _prefs.setInt(_retryDelaySecondsKey, value);
    notifyListeners();
  }

  Future<void> setSearchEngine(String value) async {
    searchEngine = value;
    await _prefs.setString(_searchEngineKey, value);
    notifyListeners();
  }

  Future<void> setThemeMode(String value) async {
    themeMode = value;
    await _prefs.setString(_themeModeKey, value);
    final resolved = value == 'dark' ? true
        : value == 'light' ? false
        : WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    if (resolved != _isDarkMode) {
      _isDarkMode = resolved;
      await _prefs.setBool(_isDarkModeKey, resolved);
    }
    notifyListeners();
  }

  Future<void> setNotificationsEnabled(bool value) async {
    notificationsEnabled = value;
    await _prefs.setBool(_notificationsEnabledKey, value);
    notifyListeners();
  }

  Future<void> setProxyHost(String value) async {
    proxyHost = value;
    await _prefs.setString(_proxyHostKey, value);
    if (proxyHost.isNotEmpty) {
      proxyAddress = '$proxyHost:$proxyPort';
      await _prefs.setString(_proxyAddressKey, proxyAddress);
    }
    notifyListeners();
  }

  Future<void> setProxyPort(int value) async {
    proxyPort = value;
    await _prefs.setInt(_proxyPortKey, value);
    if (proxyHost.isNotEmpty) {
      proxyAddress = '$proxyHost:$proxyPort';
      await _prefs.setString(_proxyAddressKey, proxyAddress);
    }
    notifyListeners();
  }

  Future<void> setProxyUsername(String value) async {
    proxyUsername = value;
    await _prefs.setString(_proxyUsernameKey, value);
    notifyListeners();
  }

  Future<void> setProxyPassword(String value) async {
    proxyPassword = value;
    await _secureStorage.write(key: _proxyPasswordKey, value: value);
    notifyListeners();
  }

  Future<void> setBackendUrl(String value) async {
    backendUrl = value;
    await _prefs.setString(_backendUrlKey, value);
    notifyListeners();
  }

  Future<void> setBackendToken(String value) async {
    backendToken = value;
    await _secureStorage.write(key: _backendTokenKey, value: value);
    notifyListeners();
  }

  Future<void> setSendBrowserCookiesToBackend(bool value) async {
    sendBrowserCookiesToBackend = value;
    await _prefs.setBool(_sendBrowserCookiesToBackendKey, value);
    notifyListeners();
  }

  Future<bool> testProxyConnection(String host, int port, String username, String password) async {
    final client = HttpClient();
    try {
      client.connectionTimeout = const Duration(seconds: 4);
      client.findProxy = (uri) {
        return "PROXY $host:$port";
      };
      if (username.isNotEmpty) {
        client.authenticateProxy = (h, p, scheme, realm) async {
          client.addProxyCredentials(
            h,
            p,
            realm ?? '',
            HttpClientBasicCredentials(username, password),
          );
          return true;
        };
      }
      final request = await client.getUrl(Uri.parse("https://www.google.com"));
      final response = await request.close();
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Proxy connection test failed: $e');
      return false;
    } finally {
      client.close();
    }
  }

  Future<void> resetToDefaults() async {
    final settingsKeys = [
      _autoStartKey,
      _maxDownloadsKey,
      _speedLimitKey,
      _enableGlowKey,
      _gridOpacityKey,
      _soundNotificationKey,
      _vibrationKey,
      _wifiOnlyKey,
      _languageCodeKey,
      _isDarkModeKey,
      _themeModeKey,
      _showOnboardingKey,
      _classicUiKey,
      _enableProxyKey,
      _proxyAddressKey,
      _bypassSSLKey,
      _reduceVisualsKey,
      _customUserAgentKey,
      _cleanupDaysKey,
      _categoryFoldersKey,
      _globalTorrentSeedingKey,
      _globalTorrentSeedingLimitedKey,
      _globalTorrentSeedingLimitKbpsKey,
      _enableDhtKey,
      _enableUpnpKey,
      _forceEncryptKey,
      _torrentConnectionsLimitKey,
      _defaultThreadCountKey,
      _customDownloadPathKey,
      _incognitoEnabledKey,
      _desktopModeKey,
      _adBlockerEnabledKey,
      _pinchToZoomKey,
      _batterySaverModeKey,
      _saveBrowserHistoryKey,
      _notificationsEnabledKey,
      _proxyHostKey,
      _proxyPortKey,
      _proxyUsernameKey,
      _proxyPasswordKey,
      _autoRetryEnabledKey,
      _maxRetriesKey,
      _retryDelaySecondsKey,
      _searchEngineKey,
    ];
    for (final key in settingsKeys) {
      if (key == _proxyPasswordKey) {
        await _secureStorage.delete(key: key);
      } else {
        await _prefs.remove(key);
      }
    }
    _isDarkMode = true;
    _classicUi = true;
    _maxDownloads = 3;
    _defaultThreadCount = 5;
    autoStart = true;
    customDownloadPath = null;
    speedLimitMb = 0.0;
    enableGlow = true;
    gridOpacity = 12.0;
    soundNotification = true;
    vibration = false;
    wifiOnly = false;
    languageCode = 'en';
    themeMode = 'system';
    showOnboarding = true;
    batterySaverMode = false;
    enableProxy = false;
    proxyAddress = '';
    bypassSSL = false;
    reduceVisuals = false;
    customUserAgent = '';
    cleanupDays = 0;
    categoryFolders = false;
    globalTorrentSeeding = true;
    globalTorrentSeedingLimited = false;
    globalTorrentSeedingLimitKbps = 500;
    enableDht = true;
    enableUpnp = true;
    forceEncrypt = false;
    torrentConnectionsLimit = 200;
    incognitoEnabled = false;
    desktopMode = false;
    adBlockerEnabled = true;
    pinchToZoom = true;
    saveBrowserHistory = true;
    notificationsEnabled = true;
    proxyHost = '';
    proxyPort = 8080;
    proxyUsername = '';
    proxyPassword = '';
    autoRetryEnabled = true;
    maxRetries = 3;
    retryDelaySeconds = 10;
    searchEngine = 'Google';

    await _prefs.setBool(_isDarkModeKey, _isDarkMode);
    await _prefs.setBool(_classicUiKey, _classicUi);
    await _prefs.setInt(_maxDownloadsKey, _maxDownloads);
    await _prefs.setInt(_defaultThreadCountKey, _defaultThreadCount);
    await _prefs.setBool(_autoStartKey, autoStart);
    await _prefs.setDouble(_speedLimitKey, speedLimitMb);
    await _prefs.setBool(_enableGlowKey, enableGlow);
    await _prefs.setDouble(_gridOpacityKey, gridOpacity);
    await _prefs.setBool(_soundNotificationKey, soundNotification);
    await _prefs.setBool(_vibrationKey, vibration);
    await _prefs.setBool(_wifiOnlyKey, wifiOnly);
    await _prefs.setString(_languageCodeKey, languageCode);
    await _prefs.setString(_themeModeKey, themeMode);
    await _prefs.setBool(_showOnboardingKey, showOnboarding);
    await _prefs.setBool(_batterySaverModeKey, batterySaverMode);
    await _prefs.setBool(_enableProxyKey, enableProxy);
    await _prefs.setString(_proxyAddressKey, proxyAddress);
    await _prefs.setBool(_bypassSSLKey, bypassSSL);
    await _prefs.setBool(_reduceVisualsKey, reduceVisuals);
    await _prefs.setString(_customUserAgentKey, customUserAgent);
    await _prefs.setInt(_cleanupDaysKey, cleanupDays);
    await _prefs.setBool(_categoryFoldersKey, categoryFolders);
    await _prefs.setBool(_globalTorrentSeedingKey, globalTorrentSeeding);
    await _prefs.setBool(_globalTorrentSeedingLimitedKey, globalTorrentSeedingLimited);
    await _prefs.setInt(_globalTorrentSeedingLimitKbpsKey, globalTorrentSeedingLimitKbps);
    await _prefs.setBool(_enableDhtKey, enableDht);
    await _prefs.setBool(_enableUpnpKey, enableUpnp);
    await _prefs.setBool(_forceEncryptKey, forceEncrypt);
    await _prefs.setInt(_torrentConnectionsLimitKey, torrentConnectionsLimit);
    await _prefs.setBool(_incognitoEnabledKey, incognitoEnabled);
    await _prefs.setBool(_desktopModeKey, desktopMode);
    await _prefs.setBool(_adBlockerEnabledKey, adBlockerEnabled);
    await _prefs.setBool(_pinchToZoomKey, pinchToZoom);
    await _prefs.setBool(_saveBrowserHistoryKey, saveBrowserHistory);
    await _prefs.setBool(_notificationsEnabledKey, notificationsEnabled);
    await _prefs.setString(_proxyHostKey, proxyHost);
    await _prefs.setInt(_proxyPortKey, proxyPort);
    await _prefs.setString(_proxyUsernameKey, proxyUsername);
    await _prefs.setBool(_autoRetryEnabledKey, autoRetryEnabled);
    await _prefs.setInt(_maxRetriesKey, maxRetries);
    await _prefs.setInt(_retryDelaySecondsKey, retryDelaySeconds);
    await _prefs.setString(_searchEngineKey, searchEngine);
    if (customDownloadPath != null) {
      await _prefs.setString(_customDownloadPathKey, customDownloadPath!);
    }
    if (proxyPassword.isNotEmpty) {
      await _secureStorage.write(key: _proxyPasswordKey, value: proxyPassword);
    }
    notifyListeners();
  }
}
