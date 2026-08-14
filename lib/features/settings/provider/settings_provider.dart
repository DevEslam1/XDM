import 'dart:async';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../../core/services/quiet_hours.dart';
import '../../../core/services/xdm_backend_client.dart';
import '../../../core/services/power_monitor.dart';
import '../../../core/services/notification_service.dart';

class SettingsProvider extends ChangeNotifier with WidgetsBindingObserver {
  static final _log = Logger('SettingsProvider');

  static SettingsProvider? _instance;
  bool _loaded = false;
  bool _observerAdded = false;
  Completer<void>? _loadCompleter;

  static SettingsProvider get instance {
    _instance ??= SettingsProvider._internal();
    return _instance!;
  }

  SettingsProvider._internal();

  factory SettingsProvider() => instance;

  static SettingsProvider get loadedInstance {
    assert(
      _instance != null && _instance!._loaded,
      'SettingsProvider accessed before load() completed',
    );
    return _instance!;
  }

  Future<void> ensureLoaded() async {
    if (_loadCompleter != null) await _loadCompleter!.future;
  }

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
  static const _bandwidthScheduleEnabledKey = 'bandwidthScheduleEnabled';
  static const _scheduleStartTimeKey = 'scheduleStartTime';
  static const _scheduleEndTimeKey = 'scheduleEndTime';
  static const _scheduleSpeedLimitMbKey = 'scheduleSpeedLimitMb';
  static const _httpsOnlyKey = 'httpsOnly';
  static const _reduceVisualsKey = 'reduceVisuals';
  static const _textScaleFactorKey = 'textScaleFactor';
  static const _customUserAgentKey = 'customUserAgent';
  static const _cleanupDaysKey = 'cleanupDays';
  static const _categoryFoldersKey = 'categoryFolders';
  static const _globalTorrentSeedingKey = 'globalTorrentSeeding';
  static const _globalTorrentSeedingLimitedKey = 'globalTorrentSeedingLimited';
  static const _globalTorrentSeedingLimitKbpsKey =
      'globalTorrentSeedingLimitKbps';
  static const _enableDhtKey = 'enableDht';
  static const _enableUpnpKey = 'enableUpnp';
  static const _enableNatPmpKey = 'enableNatPmp';
  static const _enableLpdKey = 'enableLpd';
  static const _enablePexKey = 'enablePex';
  static const _maxActiveTorrentsKey = 'maxActiveTorrents';
  static const _maxActiveDownloadsKey = 'maxActiveDownloads';
  static const _maxActiveSeedsKey = 'maxActiveSeeds';
  static const _queueTorrentsKey = 'queueTorrents';
  static const _forceEncryptKey = 'forceEncrypt';
  static const _torrentConnectionsLimitKey = 'torrentConnectionsLimit';
  static const _sequentialDownloadKey = 'sequentialDownload';
  static const _maxConcurrentFilesPerTorrentKey =
      'maxConcurrentFilesPerTorrent';
  static const _shareRatioLimitKey = 'shareRatioLimit';
  static const _maxSeedingTimeKey = 'maxSeedingTimeMinutes';
  static const _maxPeerConnectionsPerTorrentKey =
      'maxPeerConnectionsPerTorrent';
  static const _maxHalfOpenConnectionsKey = 'maxHalfOpenConnections';
  static const _enableUtpKey = 'enableUtp';
  static const _enableLsdKey = 'enableLsd';
  static const _diskCacheSizeMbKey = 'diskCacheSizeMb';
  static const _useOsCacheKey = 'useOsCache';
  static const _seedOnlyWhenChargingKey = 'seedOnlyWhenCharging';
  static const _seedOnlyOnWifiKey = 'seedOnlyOnWifi';
  static const _enableIpFilterKey = 'enableIpFilter';
  static const _ipFilterPathKey = 'ipFilterPath';
  static const _enableAnonymousModeKey = 'enableAnonymousMode';
  static const _defaultThreadCountKey = 'defaultThreadCount';
  static const _customDownloadPathKey = 'customDownloadPath';
  static const _incognitoEnabledKey = 'incognitoEnabled';
  static const _desktopModeKey = 'desktopMode';
  static const _pinchToZoomKey = 'pinchToZoom';
  static const _batterySaverModeKey = 'batterySaverMode';
  static const _saveBrowserHistoryKey = 'saveBrowserHistory';
  static const _notificationsEnabledKey = 'notificationsEnabled';
  static const _quietHoursEnabledKey = 'quietHoursEnabled';
  static const _quietHoursStartKey = 'quietHoursStart';
  static const _quietHoursEndKey = 'quietHoursEnd';

  static const _autoRetryEnabledKey = 'autoRetryEnabled';
  static const _maxRetriesKey = 'maxRetries';
  static const _retryDelaySecondsKey = 'retryDelaySeconds';
  static const _searchEngineKey = 'searchEngine';
  static const _useRemoteBackendKey = 'use_remote_backend';
  static const _batteryOptimizationPromptedKey = 'batteryOptimizationPrompted';
  static const _maxTotalConnectionsKey = 'maxTotalConnections';
  static const _adaptiveThreadsKey = 'adaptiveThreads';
  static const _autoVerifyChecksumKey = 'autoVerifyChecksum';
  static const _maxTabsKey = 'maxTabs';
  static const _historyMaxEntriesKey = 'historyMaxEntries';
  static const _forceDarkModeKey = 'forceDarkMode';
  static const _blockImagesKey = 'blockImages';
  static const _openLinksInAppKey = 'openLinksInApp';
  static const _translateTargetLangKey = 'translateTargetLang';
  static const _formAutofillKey = 'formAutofill';
  static const _powerAwareIsolatePoolKey = 'powerAwareIsolatePool';
  static const _thermalThreadLimitingKey = 'thermalThreadLimiting';
  static const _jankAutoBatterySaverKey = 'jankAutoBatterySaver';
  static const _diskWriteBatchingKey = 'diskWriteBatching';
  static const _powerBandwidthThrottlingKey = 'powerBandwidthThrottling';
  static const _resumeIntegrityCheckKey = 'resumeIntegrityCheck';
  static const _backendUrlKey = 'backend_url';
  static const _backendTokenKey = 'backend_token';
  static const _sendBrowserCookiesToBackendKey =
      'send_browser_cookies_to_backend';
  static const _useLocalYtFallbackKey = 'use_local_yt_fallback';

  late SharedPreferences _prefs;
  final _secureStorage = const FlutterSecureStorage();

  Timer? _gridOpacityDebounce;
  Timer? _speedLimitDebounce;

  bool autoStart = true;
  String? customDownloadPath;
  int _maxDownloads = 3;
  int get maxDownloads => batterySaverMode ? 1 : _maxDownloads;
  double speedLimitMb = 0.0;
  bool bandwidthScheduleEnabled = false;
  String scheduleStartTime = '23:00';
  String scheduleEndTime = '07:00';
  double scheduleSpeedLimitMb = 0.0;
  // FIX-S7: Effective getters for batterySaverMode
  bool _enableGlow = true;
  bool get enableGlow => batterySaverMode ? false : _enableGlow;
  set enableGlow(bool value) => _enableGlow = value;
  double gridOpacity = 40.0;
  bool soundNotification = true;
  bool vibration = false;
  bool wifiOnly = false;
  String languageCode = 'en';
  bool _isDarkMode = true;

  bool get isDarkMode {
    if (themeMode == 'system') {
      try {
        final binding = WidgetsBinding.instance;
        return binding.platformDispatcher.platformBrightness == Brightness.dark;
      } catch (e, st) {
        _log.warning('[settings_provider] operation failed', e, st);
        return _isDarkMode;
      }
    }
    return themeMode == 'dark' || themeMode == 'amoled';
  }

  bool get isAmoledMode => themeMode == 'amoled';

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

  int _activeSettingsTabIndex = 0;
  int get activeSettingsTabIndex => _activeSettingsTabIndex;

  void setActiveSettingsTabIndex(int index) {
    if (_activeSettingsTabIndex != index) {
      _activeSettingsTabIndex = index;
      notifyListeners();
    }
  }

  // FIX-0.1 / FIX-0.5: developerMode cannot bypass SSL in release.
  bool developerMode = false;
  bool httpsOnly = false;
  bool _reduceVisuals = false;
  bool get reduceVisuals => batterySaverMode ? true : _reduceVisuals;
  set reduceVisuals(bool value) => _reduceVisuals = value;
  double textScaleFactor = 1.0;
  String customUserAgent = '';
  int cleanupDays = 0;
  bool categoryFolders = false;
  bool antiFingerprinting = true;

  int _maxTabs = 10;
  int get maxTabs => _maxTabs;
  set maxTabs(int value) {
    _maxTabs = value;
    _prefs.setInt(_maxTabsKey, value);
    notifyListeners();
  }

  int _historyMaxEntries = 500;
  int get historyMaxEntries => _historyMaxEntries;
  set historyMaxEntries(int value) {
    _historyMaxEntries = value;
    _prefs.setInt(_historyMaxEntriesKey, value);
    notifyListeners();
  }

  static const _antiFingerprintingKey = 'antiFingerprinting';
  static const _developerModeKey = 'developerMode';

  Future<void> setAntiFingerprinting(bool value) async {
    antiFingerprinting = value;
    await _prefs.setBool(_antiFingerprintingKey, value);
    notifyListeners();
  }

  Future<void> toggleDeveloperMode() async {
    developerMode = !developerMode;
    await _prefs.setBool(_developerModeKey, developerMode);
    notifyListeners();
  }

  String backendUrl = '';
  String backendToken = '';
  bool sendBrowserCookiesToBackend = true;
  bool useLocalYtFallback = true;

  bool globalTorrentSeeding = true;
  bool globalTorrentSeedingLimited = false;
  int globalTorrentSeedingLimitKbps = 500;
  bool enableDht = true;
  bool enableUpnp = true;
  bool enableNatPmp = true;
  bool enableLpd = true;
  bool enablePex = true;
  int maxActiveTorrents = 3;
  int maxActiveDownloads = 2;
  int maxActiveSeeds = 2;
  bool queueTorrents = true;
  bool forceEncrypt = false;
  int torrentConnectionsLimit = 200;
  bool sequentialDownload = false;
  int _maxConcurrentFilesPerTorrent = 0;
  double shareRatioLimit = 2.0;
  int maxSeedingTimeMinutes = 0;
  int maxPeerConnectionsPerTorrent = 50;
  int maxHalfOpenConnections = 20;
  bool enableUtp = true;
  bool enableLsd = true;
  int diskCacheSizeMb = 512;
  bool useOsCache = true;
  bool seedOnlyWhenCharging = false;
  bool seedOnlyOnWifi = false;
  bool enableIpFilter = false;
  String ipFilterPath = '';
  bool enableAnonymousMode = false;

  Future<void> setEnableNatPmp(bool value) async {
    enableNatPmp = value;
    await _prefs.setBool(_enableNatPmpKey, value);
    notifyListeners();
  }

  Future<void> setEnableLpd(bool value) async {
    enableLpd = value;
    await _prefs.setBool(_enableLpdKey, value);
    notifyListeners();
  }

  Future<void> setEnablePex(bool value) async {
    enablePex = value;
    await _prefs.setBool(_enablePexKey, value);
    notifyListeners();
  }

  Future<void> setMaxActiveTorrents(int value) async {
    maxActiveTorrents = value.clamp(1, 50);
    await _prefs.setInt(_maxActiveTorrentsKey, maxActiveTorrents);
    notifyListeners();
  }

  Future<void> setMaxActiveDownloads(int value) async {
    maxActiveDownloads = value.clamp(1, 20);
    await _prefs.setInt(_maxActiveDownloadsKey, maxActiveDownloads);
    notifyListeners();
  }

  Future<void> setMaxActiveSeeds(int value) async {
    maxActiveSeeds = value.clamp(0, 20);
    await _prefs.setInt(_maxActiveSeedsKey, maxActiveSeeds);
    notifyListeners();
  }

  Future<void> setQueueTorrents(bool value) async {
    queueTorrents = value;
    await _prefs.setBool(_queueTorrentsKey, value);
    notifyListeners();
  }

  int get maxConcurrentFilesPerTorrent => _maxConcurrentFilesPerTorrent;

  Future<void> setMaxConcurrentFilesPerTorrent(int value) async {
    _maxConcurrentFilesPerTorrent = value;
    await _prefs.setInt(_maxConcurrentFilesPerTorrentKey, value);
    notifyListeners();
  }

  int get configuredMaxDownloads => _maxDownloads;
  bool get configuredClassicUi => _classicUi;
  int get configuredDefaultThreadCount => _defaultThreadCount;
  int get effectiveMaxDownloads => batterySaverMode ? 1 : _maxDownloads;
  bool get effectiveClassicUi => batterySaverMode ? true : _classicUi;
  int get effectiveDefaultThreadCount =>
      batterySaverMode ? 2 : _defaultThreadCount;

  int _defaultThreadCount = 16;
  int get defaultThreadCount => batterySaverMode ? 2 : _defaultThreadCount;

  bool incognitoEnabled = false;
  bool desktopMode = false;
  bool pinchToZoom = true;
  bool saveBrowserHistory = true;
  bool forceDarkMode = false;
  bool blockImages = false;
  bool openLinksInApp = false;
  String translateTargetLang = 'en';
  bool formAutofill = true;
  bool notificationsEnabled = true;
  bool quietHoursEnabled = false;
  String quietHoursStart = '23:00';
  String quietHoursEnd = '07:00';

  bool autoRetryEnabled = true;
  int maxRetries = 3;
  int retryDelaySeconds = 3;
  String searchEngine = 'Google';
  bool useRemoteBackend = true;
  bool batteryOptimizationPrompted = false;
  int _maxTotalConnections = 32;
  int get maxTotalConnections => _maxTotalConnections;
  bool adaptiveThreads = false;
  bool autoVerifyChecksum = false;
  bool powerAwareIsolatePool = true;
  bool thermalThreadLimiting = true;
  bool jankAutoBatterySaver = false;
  bool diskWriteBatching = true;
  bool powerBandwidthThrottling = true;
  bool resumeIntegrityCheck = true;

  @override
  void didChangePlatformBrightness() {
    if (themeMode == 'system') {
      final newDark =
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark;
      if (newDark != _isDarkMode) {
        _isDarkMode = newDark;
        notifyListeners();
      }
    }
  }

  Future<void> load() async {
    // FIX MISC-1: Ensure load() is strictly idempotent
    if (_loaded) return;
    if (_loadCompleter != null) return _loadCompleter!.future;
    _loadCompleter = Completer<void>();

    try {
      _prefs = await SharedPreferences.getInstance();

      // FIX: Only add observer once
      if (!_observerAdded) {
        WidgetsBinding.instance.addObserver(this);
        _observerAdded = true;
      }

      autoStart = _prefs.getBool(_autoStartKey) ?? autoStart;
      _maxDownloads = _prefs.getInt(_maxDownloadsKey) ?? _maxDownloads;
      if (![1, 2, 3, 5, 8].contains(_maxDownloads)) _maxDownloads = 3;
      speedLimitMb = _prefs.getDouble(_speedLimitKey) ?? speedLimitMb;
      bandwidthScheduleEnabled = _prefs.getBool(_bandwidthScheduleEnabledKey) ??
          bandwidthScheduleEnabled;
      scheduleStartTime =
          _prefs.getString(_scheduleStartTimeKey) ?? scheduleStartTime;
      scheduleEndTime =
          _prefs.getString(_scheduleEndTimeKey) ?? scheduleEndTime;
      scheduleSpeedLimitMb =
          _prefs.getDouble(_scheduleSpeedLimitMbKey) ?? scheduleSpeedLimitMb;
      enableGlow = _prefs.getBool(_enableGlowKey) ?? enableGlow;
      gridOpacity = _prefs.getDouble(_gridOpacityKey) ?? gridOpacity;
      soundNotification =
          _prefs.getBool(_soundNotificationKey) ?? soundNotification;
      vibration = _prefs.getBool(_vibrationKey) ?? vibration;
      wifiOnly = _prefs.getBool(_wifiOnlyKey) ?? wifiOnly;
      languageCode = _prefs.getString(_languageCodeKey) ?? languageCode;
      themeMode = _prefs.getString(_themeModeKey) ?? 'system';
      if (!['light', 'dark', 'amoled', 'system'].contains(themeMode)) {
        themeMode = 'system';
      }
      _isDarkMode = _prefs.getBool(_isDarkModeKey) ?? isDarkMode;
      showOnboarding = _prefs.getBool(_showOnboardingKey) ?? showOnboarding;
      _classicUi = _prefs.getBool(_classicUiKey) ?? _classicUi;
      batterySaverMode =
          _prefs.getBool(_batterySaverModeKey) ?? batterySaverMode;
      developerMode = _prefs.getBool(_developerModeKey) ?? false;
      httpsOnly = _prefs.getBool(_httpsOnlyKey) ?? httpsOnly;
      reduceVisuals = _prefs.getBool(_reduceVisualsKey) ?? reduceVisuals;
      textScaleFactor =
          _prefs.getDouble(_textScaleFactorKey) ?? textScaleFactor;
      customUserAgent =
          _prefs.getString(_customUserAgentKey) ?? customUserAgent;
      cleanupDays = _prefs.getInt(_cleanupDaysKey) ?? cleanupDays;
      if (![0, 7, 30].contains(cleanupDays)) cleanupDays = 0;
      categoryFolders = _prefs.getBool(_categoryFoldersKey) ?? categoryFolders;
      antiFingerprinting =
          _prefs.getBool(_antiFingerprintingKey) ?? antiFingerprinting;
      backendUrl = _prefs.getString(_backendUrlKey) ?? backendUrl;
      backendToken = await _secureStorage.read(key: _backendTokenKey) ?? '';
      sendBrowserCookiesToBackend =
          _prefs.getBool(_sendBrowserCookiesToBackendKey) ??
              sendBrowserCookiesToBackend;
      useLocalYtFallback =
          _prefs.getBool(_useLocalYtFallbackKey) ?? useLocalYtFallback;
      globalTorrentSeeding =
          _prefs.getBool(_globalTorrentSeedingKey) ?? globalTorrentSeeding;
      globalTorrentSeedingLimited =
          _prefs.getBool(_globalTorrentSeedingLimitedKey) ??
              globalTorrentSeedingLimited;
      globalTorrentSeedingLimitKbps =
          _prefs.getInt(_globalTorrentSeedingLimitKbpsKey) ??
              globalTorrentSeedingLimitKbps;
      enableDht = _prefs.getBool(_enableDhtKey) ?? enableDht;
      enableUpnp = _prefs.getBool(_enableUpnpKey) ?? enableUpnp;
      enableNatPmp = _prefs.getBool(_enableNatPmpKey) ?? enableNatPmp;
      enableLpd = _prefs.getBool(_enableLpdKey) ?? enableLpd;
      enablePex = _prefs.getBool(_enablePexKey) ?? enablePex;
      maxActiveTorrents =
          _prefs.getInt(_maxActiveTorrentsKey) ?? maxActiveTorrents;
      maxActiveDownloads =
          _prefs.getInt(_maxActiveDownloadsKey) ?? maxActiveDownloads;
      maxActiveSeeds = _prefs.getInt(_maxActiveSeedsKey) ?? maxActiveSeeds;
      queueTorrents = _prefs.getBool(_queueTorrentsKey) ?? queueTorrents;
      forceEncrypt = _prefs.getBool(_forceEncryptKey) ?? forceEncrypt;
      torrentConnectionsLimit = (_prefs.getInt(_torrentConnectionsLimitKey) ??
              torrentConnectionsLimit)
          .clamp(10, 1000);
      sequentialDownload =
          _prefs.getBool(_sequentialDownloadKey) ?? sequentialDownload;
      _maxConcurrentFilesPerTorrent =
          _prefs.getInt(_maxConcurrentFilesPerTorrentKey) ?? 0;
      shareRatioLimit =
          _prefs.getDouble(_shareRatioLimitKey) ?? shareRatioLimit;
      maxSeedingTimeMinutes =
          _prefs.getInt(_maxSeedingTimeKey) ?? maxSeedingTimeMinutes;
      maxPeerConnectionsPerTorrent =
          _prefs.getInt(_maxPeerConnectionsPerTorrentKey) ??
              maxPeerConnectionsPerTorrent;
      maxHalfOpenConnections =
          _prefs.getInt(_maxHalfOpenConnectionsKey) ?? maxHalfOpenConnections;
      enableUtp = _prefs.getBool(_enableUtpKey) ?? enableUtp;
      enableLsd = _prefs.getBool(_enableLsdKey) ?? enableLsd;
      diskCacheSizeMb = _prefs.getInt(_diskCacheSizeMbKey) ?? diskCacheSizeMb;
      useOsCache = _prefs.getBool(_useOsCacheKey) ?? useOsCache;
      seedOnlyWhenCharging =
          _prefs.getBool(_seedOnlyWhenChargingKey) ?? seedOnlyWhenCharging;
      seedOnlyOnWifi = _prefs.getBool(_seedOnlyOnWifiKey) ?? seedOnlyOnWifi;
      enableIpFilter = _prefs.getBool(_enableIpFilterKey) ?? enableIpFilter;
      ipFilterPath = _prefs.getString(_ipFilterPathKey) ?? ipFilterPath;
      enableAnonymousMode =
          _prefs.getBool(_enableAnonymousModeKey) ?? enableAnonymousMode;
      _defaultThreadCount =
          _prefs.getInt(_defaultThreadCountKey) ?? _defaultThreadCount;
      if (![1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 16].contains(_defaultThreadCount)) {
        _defaultThreadCount = 16;
      }
      customDownloadPath = _prefs.getString(_customDownloadPathKey);
      incognitoEnabled =
          _prefs.getBool(_incognitoEnabledKey) ?? incognitoEnabled;
      desktopMode = _prefs.getBool(_desktopModeKey) ?? desktopMode;
      pinchToZoom = _prefs.getBool(_pinchToZoomKey) ?? pinchToZoom;
      _maxTabs = _prefs.getInt(_maxTabsKey) ?? 10;
      _historyMaxEntries = _prefs.getInt(_historyMaxEntriesKey) ?? 500;
      saveBrowserHistory =
          _prefs.getBool(_saveBrowserHistoryKey) ?? saveBrowserHistory;
      forceDarkMode = _prefs.getBool(_forceDarkModeKey) ?? forceDarkMode;
      blockImages = _prefs.getBool(_blockImagesKey) ?? blockImages;
      openLinksInApp = _prefs.getBool(_openLinksInAppKey) ?? openLinksInApp;
      translateTargetLang =
          _prefs.getString(_translateTargetLangKey) ?? translateTargetLang;
      formAutofill = _prefs.getBool(_formAutofillKey) ?? formAutofill;
      notificationsEnabled = _prefs.getBool(_notificationsEnabledKey) ?? true;
      quietHoursEnabled =
          _prefs.getBool(_quietHoursEnabledKey) ?? quietHoursEnabled;
      quietHoursStart =
          _prefs.getString(_quietHoursStartKey) ?? quietHoursStart;
      quietHoursEnd = _prefs.getString(_quietHoursEndKey) ?? quietHoursEnd;
      autoRetryEnabled =
          _prefs.getBool(_autoRetryEnabledKey) ?? autoRetryEnabled;
      maxRetries = _prefs.getInt(_maxRetriesKey) ?? maxRetries;
      if (![1, 2, 3, 5, 10].contains(maxRetries)) {
        maxRetries = 3;
      }
      retryDelaySeconds =
          _prefs.getInt(_retryDelaySecondsKey) ?? retryDelaySeconds;
      if (![5, 10, 30, 60].contains(retryDelaySeconds)) {
        retryDelaySeconds = 10;
      }
      searchEngine = _prefs.getString(_searchEngineKey) ?? searchEngine;
      useRemoteBackend = _prefs.getBool(_useRemoteBackendKey) ?? true;
      batteryOptimizationPrompted =
          _prefs.getBool(_batteryOptimizationPromptedKey) ?? false;
      _maxTotalConnections = _prefs.getInt(_maxTotalConnectionsKey) ?? 32;
      if (![8, 16, 24, 32, 48, 64].contains(_maxTotalConnections)) {
        _maxTotalConnections = 32;
      }
      adaptiveThreads = _prefs.getBool(_adaptiveThreadsKey) ?? false;
      autoVerifyChecksum = _prefs.getBool(_autoVerifyChecksumKey) ?? false;
      powerAwareIsolatePool = _prefs.getBool(_powerAwareIsolatePoolKey) ?? true;
      thermalThreadLimiting = _prefs.getBool(_thermalThreadLimitingKey) ?? true;
      jankAutoBatterySaver = _prefs.getBool(_jankAutoBatterySaverKey) ?? false;
      diskWriteBatching = _prefs.getBool(_diskWriteBatchingKey) ?? true;
      powerBandwidthThrottling =
          _prefs.getBool(_powerBandwidthThrottlingKey) ?? true;
      resumeIntegrityCheck = _prefs.getBool(_resumeIntegrityCheckKey) ?? true;

      PowerMonitor.thermalThreadLimitingEnabled = thermalThreadLimiting;
      PowerMonitor.powerBandwidthThrottlingEnabled = powerBandwidthThrottling;

      _loaded = true;
      _instance = this;
      if (!(_loadCompleter?.isCompleted ?? true)) {
        _loadCompleter?.complete();
      }
    } catch (e) {
      if (!(_loadCompleter?.isCompleted ?? true)) {
        _loadCompleter?.completeError(e);
      }
      _loadCompleter = null;
      rethrow;
    }
  }

  Future<void> setPowerAwareIsolatePool(bool value) async {
    powerAwareIsolatePool = value;
    await _prefs.setBool(_powerAwareIsolatePoolKey, value);
    notifyListeners();
  }

  Future<void> setThermalThreadLimiting(bool value) async {
    thermalThreadLimiting = value;
    PowerMonitor.thermalThreadLimitingEnabled = value;
    await _prefs.setBool(_thermalThreadLimitingKey, value);
    notifyListeners();
  }

  Future<void> setJankAutoBatterySaver(bool value) async {
    jankAutoBatterySaver = value;
    await _prefs.setBool(_jankAutoBatterySaverKey, value);
    notifyListeners();
  }

  Future<void> setDiskWriteBatching(bool value) async {
    diskWriteBatching = value;
    await _prefs.setBool(_diskWriteBatchingKey, value);
    notifyListeners();
  }

  Future<void> setPowerBandwidthThrottling(bool value) async {
    powerBandwidthThrottling = value;
    PowerMonitor.powerBandwidthThrottlingEnabled = value;
    await _prefs.setBool(_powerBandwidthThrottlingKey, value);
    notifyListeners();
  }

  int get speedLimitBytesPerSecond => (speedLimitMb * 1024 * 1024).round();

  int get effectiveSpeedLimitBytesPerSecond {
    if (bandwidthScheduleEnabled &&
        QuietHours.isInQuietHours(
          start: scheduleStartTime,
          end: scheduleEndTime,
        )) {
      final scheduleLimit = (scheduleSpeedLimitMb * 1024 * 1024).round();
      if (scheduleLimit > 0 &&
          (speedLimitBytesPerSecond == 0 ||
              scheduleLimit < speedLimitBytesPerSecond)) {
        return scheduleLimit;
      }
    }
    return speedLimitBytesPerSecond;
  }

  Future<void> setBandwidthScheduleEnabled(bool value) async {
    bandwidthScheduleEnabled = value;
    await _prefs.setBool(_bandwidthScheduleEnabledKey, value);
    notifyListeners();
  }

  Future<void> setScheduleStartTime(String value) async {
    scheduleStartTime = value;
    await _prefs.setString(_scheduleStartTimeKey, value);
    notifyListeners();
  }

  Future<void> setScheduleEndTime(String value) async {
    scheduleEndTime = value;
    await _prefs.setString(_scheduleEndTimeKey, value);
    notifyListeners();
  }

  Future<void> setScheduleSpeedLimitMb(double value) async {
    scheduleSpeedLimitMb = value;
    await _prefs.setDouble(_scheduleSpeedLimitMbKey, value);
    notifyListeners();
  }

  Future<void> setAutoStart(bool value) async {
    autoStart = value;
    await _prefs.setBool(_autoStartKey, value);
    notifyListeners();
  }

  Future<void> setAdaptiveThreads(bool value) async {
    adaptiveThreads = value;
    await _prefs.setBool(_adaptiveThreadsKey, value);
    notifyListeners();
  }

  Future<void> setAutoVerifyChecksum(bool value) async {
    autoVerifyChecksum = value;
    await _prefs.setBool(_autoVerifyChecksumKey, value);
    notifyListeners();
  }

  Future<void> setMaxDownloads(int value) async {
    _maxDownloads = value.clamp(1, 10);
    await _prefs.setInt(_maxDownloadsKey, _maxDownloads);
    notifyListeners();
  }

  Future<void> setSpeedLimit(double value) async {
    speedLimitMb = value;
    _speedLimitDebounce?.cancel();
    _speedLimitDebounce = Timer(const Duration(milliseconds: 500), () {
      _prefs.setDouble(_speedLimitKey, value);
      notifyListeners();
    });
  }

  Future<void> setEnableGlow(bool value) async {
    enableGlow = value;
    await _prefs.setBool(_enableGlowKey, value);
    notifyListeners();
  }

  Future<void> setGridOpacity(double value) async {
    gridOpacity = value;
    _gridOpacityDebounce?.cancel();
    _gridOpacityDebounce = Timer(const Duration(milliseconds: 500), () {
      _prefs.setDouble(_gridOpacityKey, value);
      notifyListeners();
    });
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

  Future<void> setHttpsOnly(bool value) async {
    httpsOnly = value;
    await _prefs.setBool(_httpsOnlyKey, value);
    notifyListeners();
  }

  Future<void> setReduceVisuals(bool value) async {
    reduceVisuals = value;
    await _prefs.setBool(_reduceVisualsKey, value);
    notifyListeners();
  }

  // FIX: Clamp textScaleFactor to safe bounds
  Future<void> setTextScaleFactor(double value) async {
    textScaleFactor = value.clamp(0.8, 2.5);
    await _prefs.setDouble(_textScaleFactorKey, textScaleFactor);
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

  Future<void> setSequentialDownload(bool value) async {
    sequentialDownload = value;
    await _prefs.setBool(_sequentialDownloadKey, value);
    notifyListeners();
  }

  Future<void> setShareRatioLimit(double value) async {
    shareRatioLimit = value;
    await _prefs.setDouble(_shareRatioLimitKey, value);
    notifyListeners();
  }

  Future<void> setMaxSeedingTime(int value) async {
    maxSeedingTimeMinutes = value;
    await _prefs.setInt(_maxSeedingTimeKey, value);
    notifyListeners();
  }

  Future<void> setMaxPeerConnectionsPerTorrent(int value) async {
    maxPeerConnectionsPerTorrent = value.clamp(5, 500);
    await _prefs.setInt(
        _maxPeerConnectionsPerTorrentKey, maxPeerConnectionsPerTorrent);
    notifyListeners();
  }

  Future<void> setMaxHalfOpenConnections(int value) async {
    maxHalfOpenConnections = value.clamp(1, 100);
    await _prefs.setInt(_maxHalfOpenConnectionsKey, maxHalfOpenConnections);
    notifyListeners();
  }

  Future<void> setEnableUtp(bool value) async {
    enableUtp = value;
    await _prefs.setBool(_enableUtpKey, value);
    notifyListeners();
  }

  Future<void> setEnableLsd(bool value) async {
    enableLsd = value;
    await _prefs.setBool(_enableLsdKey, value);
    notifyListeners();
  }

  Future<void> setDiskCacheSizeMb(int value) async {
    diskCacheSizeMb = value.clamp(16, 4096);
    await _prefs.setInt(_diskCacheSizeMbKey, diskCacheSizeMb);
    notifyListeners();
  }

  Future<void> setUseOsCache(bool value) async {
    useOsCache = value;
    await _prefs.setBool(_useOsCacheKey, value);
    notifyListeners();
  }

  Future<void> setSeedOnlyWhenCharging(bool value) async {
    seedOnlyWhenCharging = value;
    await _prefs.setBool(_seedOnlyWhenChargingKey, value);
    notifyListeners();
  }

  Future<void> setSeedOnlyOnWifi(bool value) async {
    seedOnlyOnWifi = value;
    await _prefs.setBool(_seedOnlyOnWifiKey, value);
    notifyListeners();
  }

  Future<void> setEnableIpFilter(bool value) async {
    enableIpFilter = value;
    await _prefs.setBool(_enableIpFilterKey, value);
    notifyListeners();
  }

  Future<void> setIpFilterPath(String value) async {
    ipFilterPath = value;
    await _prefs.setString(_ipFilterPathKey, value);
    notifyListeners();
  }

  Future<void> setEnableAnonymousMode(bool value) async {
    enableAnonymousMode = value;
    await _prefs.setBool(_enableAnonymousModeKey, value);
    notifyListeners();
  }

  Future<void> setDefaultThreadCount(int value) async {
    _defaultThreadCount = value.clamp(1, 32);
    await _prefs.setInt(_defaultThreadCountKey, _defaultThreadCount);
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

  Future<void> setForceDarkMode(bool value) async {
    forceDarkMode = value;
    await _prefs.setBool(_forceDarkModeKey, value);
    notifyListeners();
  }

  Future<void> setBlockImages(bool value) async {
    blockImages = value;
    await _prefs.setBool(_blockImagesKey, value);
    notifyListeners();
  }

  Future<void> setOpenLinksInApp(bool value) async {
    openLinksInApp = value;
    await _prefs.setBool(_openLinksInAppKey, value);
    notifyListeners();
  }

  Future<void> setTranslateTargetLang(String value) async {
    translateTargetLang = value;
    await _prefs.setString(_translateTargetLangKey, value);
    notifyListeners();
  }

  Future<void> setFormAutofill(bool value) async {
    formAutofill = value;
    await _prefs.setBool(_formAutofillKey, value);
    notifyListeners();
  }

  ThemeMode get currentThemeMode {
    switch (themeMode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
      case 'amoled':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setResumeIntegrityCheck(bool value) async {
    resumeIntegrityCheck = value;
    await _prefs.setBool(_resumeIntegrityCheckKey, value);
    notifyListeners();
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
    if (!['light', 'dark', 'amoled', 'system'].contains(value)) return;
    themeMode = value;
    await _prefs.setString(_themeModeKey, value);
    final resolved = (value == 'dark' || value == 'amoled')
        ? true
        : value == 'light'
            ? false
            : WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                Brightness.dark;
    if (resolved != _isDarkMode) {
      _isDarkMode = resolved;
      await _prefs.setBool(_isDarkModeKey, resolved);
    }
    notifyListeners();
  }

  Future<void> setNotificationsEnabled(bool value) async {
    notificationsEnabled = value;
    await _prefs.setBool(_notificationsEnabledKey, value);
    if (!value) {
      unawaited(NotificationService().cancelAll());
    }
    notifyListeners();
  }

  Future<void> setQuietHoursEnabled(bool value) async {
    quietHoursEnabled = value;
    await _prefs.setBool(_quietHoursEnabledKey, value);
    notifyListeners();
  }

  Future<void> setQuietHoursStart(String value) async {
    quietHoursStart = value;
    await _prefs.setString(_quietHoursStartKey, value);
    notifyListeners();
  }

  Future<void> setQuietHoursEnd(String value) async {
    quietHoursEnd = value;
    await _prefs.setString(_quietHoursEndKey, value);
    notifyListeners();
  }

  bool isInQuietHoursNow([DateTime? now]) {
    if (!quietHoursEnabled) return false;
    return QuietHours.isInQuietHours(
      start: quietHoursStart,
      end: quietHoursEnd,
      now: now,
    );
  }

  Future<void> setBackendUrl(String value) async {
    backendUrl = value;
    await _prefs.setString(_backendUrlKey, value);
    XdmBackendClient().refreshConfig();
    notifyListeners();
  }

  Future<void> setBackendToken(String value) async {
    backendToken = value;
    await _secureStorage.write(key: _backendTokenKey, value: value);
    XdmBackendClient().refreshConfig();
    notifyListeners();
  }

  Future<void> setSendBrowserCookiesToBackend(bool value) async {
    sendBrowserCookiesToBackend = value;
    await _prefs.setBool(_sendBrowserCookiesToBackendKey, value);
    notifyListeners();
  }

  Future<void> setUseLocalYtFallback(bool value) async {
    useLocalYtFallback = value;
    await _prefs.setBool(_useLocalYtFallbackKey, value);
    notifyListeners();
  }

  Future<void> setBatteryOptimizationPrompted(bool value) async {
    batteryOptimizationPrompted = value;
    await _prefs.setBool(_batteryOptimizationPromptedKey, value);
  }

  Future<void> setMaxTotalConnections(int value) async {
    _maxTotalConnections = value;
    await _prefs.setInt(_maxTotalConnectionsKey, value);
    notifyListeners();
  }

  Future<void> resetToDefaults() async {
    final settingsKeys = [
      _autoStartKey,
      _maxDownloadsKey,
      _speedLimitKey,
      _bandwidthScheduleEnabledKey,
      _scheduleStartTimeKey,
      _scheduleEndTimeKey,
      _scheduleSpeedLimitMbKey,
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
      _httpsOnlyKey,
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
      _sequentialDownloadKey,
      _maxConcurrentFilesPerTorrentKey,
      _shareRatioLimitKey,
      _maxSeedingTimeKey,
      _defaultThreadCountKey,
      _customDownloadPathKey,
      _incognitoEnabledKey,
      _desktopModeKey,
      _pinchToZoomKey,
      _batterySaverModeKey,
      _saveBrowserHistoryKey,
      _notificationsEnabledKey,
      _quietHoursEnabledKey,
      _quietHoursStartKey,
      _quietHoursEndKey,
      _autoRetryEnabledKey,
      _maxRetriesKey,
      _retryDelaySecondsKey,
      _searchEngineKey,
      _batteryOptimizationPromptedKey,
      _maxTotalConnectionsKey,
      _backendUrlKey,
      _backendTokenKey,
      _sendBrowserCookiesToBackendKey,
      _useRemoteBackendKey,
      _useLocalYtFallbackKey,
      _maxTabsKey,
      _historyMaxEntriesKey,
      _developerModeKey,
      _antiFingerprintingKey,
      _forceDarkModeKey,
      _blockImagesKey,
      _openLinksInAppKey,
      _translateTargetLangKey,
      _formAutofillKey,
    ];

    final removals = <Future<dynamic>>[];
    for (final key in settingsKeys) {
      if (key == _backendTokenKey) {
        removals.add(_secureStorage.delete(key: key));
      } else {
        removals.add(_prefs.remove(key));
      }
    }
    await Future.wait(removals);

    _isDarkMode = true;
    _classicUi = true;
    _maxDownloads = 3;
    _defaultThreadCount = 16;
    autoStart = true;
    customDownloadPath = null;
    speedLimitMb = 0.0;
    bandwidthScheduleEnabled = false;
    scheduleStartTime = '23:00';
    scheduleEndTime = '07:00';
    scheduleSpeedLimitMb = 0.0;
    enableGlow = true;
    gridOpacity = 40.0;
    soundNotification = true;
    vibration = false;
    wifiOnly = false;
    languageCode = 'en';
    themeMode = 'system';
    showOnboarding = true;
    batterySaverMode = false;
    httpsOnly = false;

    reduceVisuals = false;
    textScaleFactor = 1.0;
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
    sequentialDownload = false;
    _maxConcurrentFilesPerTorrent = 0;
    shareRatioLimit = 2.0;
    maxSeedingTimeMinutes = 0;
    incognitoEnabled = false;
    desktopMode = false;
    pinchToZoom = true;
    saveBrowserHistory = true;
    forceDarkMode = false;
    blockImages = false;
    openLinksInApp = false;
    translateTargetLang = 'en';
    formAutofill = true;
    notificationsEnabled = true;
    quietHoursEnabled = false;
    quietHoursStart = '23:00';
    quietHoursEnd = '07:00';

    autoRetryEnabled = true;
    maxRetries = 3;
    retryDelaySeconds = 10;
    searchEngine = 'Google';
    batteryOptimizationPrompted = false;
    _maxTotalConnections = 32;
    backendUrl = '';
    backendToken = '';
    sendBrowserCookiesToBackend = true;
    useRemoteBackend = true;
    useLocalYtFallback = false;
    resumeIntegrityCheck = true;
    _maxTabs = 10;
    _historyMaxEntries = 500;
    developerMode = false;
    antiFingerprinting = true;

    await _prefs.setBool(_isDarkModeKey, _isDarkMode);
    await _prefs.setBool(_classicUiKey, _classicUi);
    await _prefs.setInt(_maxDownloadsKey, _maxDownloads);
    await _prefs.setInt(_defaultThreadCountKey, _defaultThreadCount);
    await _prefs.setBool(_autoStartKey, autoStart);
    await _prefs.setDouble(_speedLimitKey, speedLimitMb);
    await _prefs.setBool(
        _bandwidthScheduleEnabledKey, bandwidthScheduleEnabled);
    await _prefs.setString(_scheduleStartTimeKey, scheduleStartTime);
    await _prefs.setString(_scheduleEndTimeKey, scheduleEndTime);
    await _prefs.setDouble(_scheduleSpeedLimitMbKey, scheduleSpeedLimitMb);
    await _prefs.setBool(_enableGlowKey, enableGlow);
    await _prefs.setDouble(_gridOpacityKey, gridOpacity);
    await _prefs.setBool(_soundNotificationKey, soundNotification);
    await _prefs.setBool(_vibrationKey, vibration);
    await _prefs.setBool(_wifiOnlyKey, wifiOnly);
    await _prefs.setString(_languageCodeKey, languageCode);
    await _prefs.setString(_themeModeKey, themeMode);
    await _prefs.setBool(_showOnboardingKey, showOnboarding);
    await _prefs.setBool(_batterySaverModeKey, batterySaverMode);

    await _prefs.setBool(_httpsOnlyKey, httpsOnly);
    await _prefs.setBool(_reduceVisualsKey, reduceVisuals);
    await _prefs.setDouble(_textScaleFactorKey, textScaleFactor);
    await _prefs.setString(_customUserAgentKey, customUserAgent);
    await _prefs.setInt(_cleanupDaysKey, cleanupDays);
    await _prefs.setBool(_categoryFoldersKey, categoryFolders);
    await _prefs.setBool(_globalTorrentSeedingKey, globalTorrentSeeding);
    await _prefs.setBool(
        _globalTorrentSeedingLimitedKey, globalTorrentSeedingLimited);
    await _prefs.setInt(
        _globalTorrentSeedingLimitKbpsKey, globalTorrentSeedingLimitKbps);
    await _prefs.setBool(_enableDhtKey, enableDht);
    await _prefs.setBool(_enableUpnpKey, enableUpnp);
    await _prefs.setBool(_forceEncryptKey, forceEncrypt);
    await _prefs.setInt(_torrentConnectionsLimitKey, torrentConnectionsLimit);
    await _prefs.setBool(_incognitoEnabledKey, incognitoEnabled);
    await _prefs.setBool(_desktopModeKey, desktopMode);
    await _prefs.setBool(_pinchToZoomKey, pinchToZoom);
    await _prefs.setBool(_saveBrowserHistoryKey, saveBrowserHistory);
    await _prefs.setBool(_forceDarkModeKey, forceDarkMode);
    await _prefs.setBool(_blockImagesKey, blockImages);
    await _prefs.setBool(_openLinksInAppKey, openLinksInApp);
    await _prefs.setString(_translateTargetLangKey, translateTargetLang);
    await _prefs.setBool(_formAutofillKey, formAutofill);
    await _prefs.setBool(_notificationsEnabledKey, notificationsEnabled);
    await _prefs.setBool(_quietHoursEnabledKey, quietHoursEnabled);
    await _prefs.setString(_quietHoursStartKey, quietHoursStart);
    await _prefs.setString(_quietHoursEndKey, quietHoursEnd);

    await _prefs.setBool(_autoRetryEnabledKey, autoRetryEnabled);
    await _prefs.setInt(_maxRetriesKey, maxRetries);
    await _prefs.setInt(_retryDelaySecondsKey, retryDelaySeconds);
    await _prefs.setString(_searchEngineKey, searchEngine);
    await _prefs.setBool(
        _batteryOptimizationPromptedKey, batteryOptimizationPrompted);
    await _prefs.setInt(_maxTotalConnectionsKey, _maxTotalConnections);
    await _prefs.setString(_backendUrlKey, backendUrl);
    await _prefs.setBool(
        _sendBrowserCookiesToBackendKey, sendBrowserCookiesToBackend);
    await _prefs.setBool(_useRemoteBackendKey, useRemoteBackend);
    await _prefs.setBool(_developerModeKey, developerMode);
    await _prefs.setBool(_antiFingerprintingKey, antiFingerprinting);
    await _prefs.setBool(_useLocalYtFallbackKey, useLocalYtFallback);
    await _prefs.setInt(_maxTabsKey, _maxTabs);
    await _prefs.setInt(_historyMaxEntriesKey, _historyMaxEntries);

    if (customDownloadPath != null) {
      await _prefs.setString(_customDownloadPathKey, customDownloadPath!);
    }

    XdmBackendClient().refreshConfig();
    notifyListeners();
  }

  @override
  void dispose() {
    if (_observerAdded) {
      WidgetsBinding.instance.removeObserver(this);
      _observerAdded = false;
    }
    super.dispose();
  }
}
