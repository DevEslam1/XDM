import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../../core/services/quiet_hours.dart';
import '../../../core/services/xdm_backend_client.dart';
import '../../../core/services/power_monitor.dart';

class SettingsProvider extends ChangeNotifier with WidgetsBindingObserver {
  // FIX(R5): Logger instance
  static final _log = Logger('SettingsProvider');

  /// The global singleton instance, set once during app startup.
  /// Used by services like [YoutubeService] that need access to settings
  /// without receiving the instance via dependency injection.
  static SettingsProvider? _instance;
  bool _loaded = false;
  static SettingsProvider get instance {
    _instance ??= SettingsProvider._internal();
    return _instance!;
  }

  SettingsProvider._internal();

  factory SettingsProvider() => instance;

  /// Call this instead of `instance` when you need guaranteed-loaded settings.
  static SettingsProvider get loadedInstance {
    assert(
      _instance != null && _instance!._loaded,
      'SettingsProvider accessed before load() completed',
    );
    return _instance!;
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

  static const _enableProxyKey = 'enableProxy';
  static const _proxyAddressKey = 'proxyAddress';
  static const _bypassSSLKey = 'bypassSSL_v2'; // v2: default false
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
  static const _proxyHostKey = 'proxyHost';
  static const _proxyPortKey = 'proxyPort';
  static const _proxyUsernameKey = 'proxyUsername';
  static const _proxyPasswordKey = 'proxyPassword';
  static const _autoRetryEnabledKey = 'autoRetryEnabled';
  static const _maxRetriesKey = 'maxRetries';
  static const _retryDelaySecondsKey = 'retryDelaySeconds';
  static const _searchEngineKey = 'searchEngine';
  static const _useRemoteBackendKey = 'use_remote_backend';
  static const _batteryOptimizationPromptedKey = 'batteryOptimizationPrompted';
  static const _maxTotalConnectionsKey = 'maxTotalConnections';
  static const _dnsEnabledKey = 'dnsEnabled';
  static const _dnsProviderKey = 'dnsProvider';
  static const _adaptiveThreadsKey = 'adaptiveThreads';
  static const _autoVerifyChecksumKey = 'autoVerifyChecksum';

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

  // Not `final`: [load] may run more than once on the singleton (e.g. in
  // tests where each case re-loads settings with fresh mock values).
  late SharedPreferences _prefs;
  final _secureStorage = const FlutterSecureStorage();

  // Debounce timers for rapid-fire settings changes
  Timer? _gridOpacityDebounce;
  Timer? _speedLimitDebounce;

  bool autoStart = true;
  String? customDownloadPath;
  int _maxDownloads = 3;

  /// Returns the effective max downloads. When battery saver is active,
  /// this is forced to 1 regardless of the user's configured value.
  /// The configured value is preserved in [_maxDownloads] and restored
  /// when battery saver is disabled.
  int get maxDownloads => batterySaverMode ? 1 : _maxDownloads;
  double speedLimitMb = 0.0;
  bool bandwidthScheduleEnabled = false;
  String scheduleStartTime = '23:00';
  String scheduleEndTime = '07:00';
  double scheduleSpeedLimitMb = 0.0;
  bool enableGlow = true;
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
  bool developerMode = false; // P0-2: Gate advanced/risky options behind Developer Mode
  bool httpsOnly = false;
  bool reduceVisuals = false;
  double textScaleFactor = 1.0;
  String customUserAgent = '';
  int cleanupDays = 0;
  bool categoryFolders = false;
  bool antiFingerprinting = true; // Obscure browser WebView automation fingerprints

  static const _antiFingerprintingKey = 'antiFingerprinting';

  Future<void> setAntiFingerprinting(bool value) async {
    antiFingerprinting = value;
    await _prefs.setBool(_antiFingerprintingKey, value);
    notifyListeners();
  }

  void toggleDeveloperMode() {
    developerMode = !developerMode;
    if (!developerMode) {
      bypassSSL = false;
    }
    notifyListeners();
  }

  String backendUrl = '';
  String backendToken = '';
  bool sendBrowserCookiesToBackend = true;

  /// When the remote backend is unreachable (timeout / connection error),
  /// fall back to the on-device platform extractor (Android NewPipe
  /// Extractor via the `com.example.dmx/youtube_extractor` channel).
  bool useLocalYtFallback = true;

  bool dnsEnabled = true;
  String dnsProvider = 'dns.adguard.com';

  // Torrent Seeding settings
  bool globalTorrentSeeding = true;
  bool globalTorrentSeedingLimited = false;
  int globalTorrentSeedingLimitKbps = 500;

  // Advanced Torrent settings
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
  int _maxConcurrentFilesPerTorrent = 0; // 0 = unlimited
  double shareRatioLimit = 2.0;
  int maxSeedingTimeMinutes = 0;

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

  // FIX(3): Max concurrent files per torrent setting
  int get maxConcurrentFilesPerTorrent => _maxConcurrentFilesPerTorrent;

  Future<void> setMaxConcurrentFilesPerTorrent(int value) async {
    _maxConcurrentFilesPerTorrent = value;
    await _prefs.setInt(_maxConcurrentFilesPerTorrentKey, value);
    notifyListeners();
  }

  int get configuredMaxDownloads => _maxDownloads;
  bool get configuredClassicUi => _classicUi;
  int get configuredDefaultThreadCount => _defaultThreadCount;

  // Issue 5 Fix: Effective getters for battery saver mode overrides
  int get effectiveMaxDownloads => batterySaverMode ? 1 : _maxDownloads;
  bool get effectiveClassicUi => batterySaverMode ? true : _classicUi;
  int get effectiveDefaultThreadCount =>
      batterySaverMode ? 2 : _defaultThreadCount;

  int _defaultThreadCount = 16;
  int get defaultThreadCount => batterySaverMode ? 2 : _defaultThreadCount;

  // Browser settings
  bool incognitoEnabled = false;
  bool desktopMode = false;
  bool pinchToZoom = true;
  bool saveBrowserHistory = true;

  bool notificationsEnabled = true;
  bool quietHoursEnabled = false;
  String quietHoursStart = '23:00';
  String quietHoursEnd = '07:00';
  String proxyHost = '';
  int proxyPort = 8080;
  String proxyUsername = '';
  String proxyPassword = '';
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
  bool jankAutoBatterySaver = true;
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
    _prefs = await SharedPreferences.getInstance();
    WidgetsBinding.instance.addObserver(this);
    autoStart = _prefs.getBool(_autoStartKey) ?? autoStart;
    _maxDownloads = _prefs.getInt(_maxDownloadsKey) ?? _maxDownloads;
    if (![1, 2, 3, 5, 8].contains(_maxDownloads)) _maxDownloads = 3;
    speedLimitMb = _prefs.getDouble(_speedLimitKey) ?? speedLimitMb;
    bandwidthScheduleEnabled = _prefs.getBool(_bandwidthScheduleEnabledKey) ??
        bandwidthScheduleEnabled;
    scheduleStartTime =
        _prefs.getString(_scheduleStartTimeKey) ?? scheduleStartTime;
    scheduleEndTime = _prefs.getString(_scheduleEndTimeKey) ?? scheduleEndTime;
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
    // Validate themeMode value
    if (!['light', 'dark', 'system'].contains(themeMode)) {
      themeMode = 'system';
    }
    _isDarkMode = _prefs.getBool(_isDarkModeKey) ?? isDarkMode;
    showOnboarding = _prefs.getBool(_showOnboardingKey) ?? showOnboarding;
    _classicUi = _prefs.getBool(_classicUiKey) ?? _classicUi;
    batterySaverMode = _prefs.getBool(_batterySaverModeKey) ?? batterySaverMode;

    enableProxy = _prefs.getBool(_enableProxyKey) ?? enableProxy;
    proxyAddress = _prefs.getString(_proxyAddressKey) ?? proxyAddress;
    bypassSSL = _prefs.getBool(_bypassSSLKey) ?? bypassSSL;
    httpsOnly = _prefs.getBool(_httpsOnlyKey) ?? httpsOnly;
    reduceVisuals = _prefs.getBool(_reduceVisualsKey) ?? reduceVisuals;
    textScaleFactor = _prefs.getDouble(_textScaleFactorKey) ?? textScaleFactor;
    customUserAgent = _prefs.getString(_customUserAgentKey) ?? customUserAgent;
    cleanupDays = _prefs.getInt(_cleanupDaysKey) ?? cleanupDays;
    if (![0, 7, 30].contains(cleanupDays)) cleanupDays = 0;
    categoryFolders = _prefs.getBool(_categoryFoldersKey) ?? categoryFolders;
    antiFingerprinting = _prefs.getBool(_antiFingerprintingKey) ?? antiFingerprinting;

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
    torrentConnectionsLimit =
        (_prefs.getInt(_torrentConnectionsLimitKey) ?? torrentConnectionsLimit)
            .clamp(10, 1000);
    sequentialDownload =
        _prefs.getBool(_sequentialDownloadKey) ?? sequentialDownload;
    _maxConcurrentFilesPerTorrent =
        _prefs.getInt(_maxConcurrentFilesPerTorrentKey) ?? 0;
    shareRatioLimit = _prefs.getDouble(_shareRatioLimitKey) ?? shareRatioLimit;
    maxSeedingTimeMinutes =
        _prefs.getInt(_maxSeedingTimeKey) ?? maxSeedingTimeMinutes;
    _defaultThreadCount =
        _prefs.getInt(_defaultThreadCountKey) ?? _defaultThreadCount;
    if (![1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 16].contains(_defaultThreadCount)) {
      _defaultThreadCount = 16;
    }
    customDownloadPath = _prefs.getString(_customDownloadPathKey);
    incognitoEnabled = _prefs.getBool(_incognitoEnabledKey) ?? incognitoEnabled;
    desktopMode = _prefs.getBool(_desktopModeKey) ?? desktopMode;
    pinchToZoom = _prefs.getBool(_pinchToZoomKey) ?? pinchToZoom;
    saveBrowserHistory =
        _prefs.getBool(_saveBrowserHistoryKey) ?? saveBrowserHistory;
    notificationsEnabled = _prefs.getBool(_notificationsEnabledKey) ?? true;
    quietHoursEnabled =
        _prefs.getBool(_quietHoursEnabledKey) ?? quietHoursEnabled;
    quietHoursStart = _prefs.getString(_quietHoursStartKey) ?? quietHoursStart;
    quietHoursEnd = _prefs.getString(_quietHoursEndKey) ?? quietHoursEnd;
    proxyHost = _prefs.getString(_proxyHostKey) ?? '';
    proxyPort = _prefs.getInt(_proxyPortKey) ?? 8080;
    proxyUsername = _prefs.getString(_proxyUsernameKey) ?? '';

    proxyPassword = await _secureStorage.read(key: _proxyPasswordKey) ?? '';
    final legacyPassword = _prefs.getString(_proxyPasswordKey);
    if (legacyPassword != null &&
        legacyPassword.isNotEmpty &&
        proxyPassword.isEmpty) {
      proxyPassword = legacyPassword;
      await _secureStorage.write(key: _proxyPasswordKey, value: proxyPassword);
      await _prefs.remove(_proxyPasswordKey);
    }

    autoRetryEnabled = _prefs.getBool(_autoRetryEnabledKey) ?? autoRetryEnabled;
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
    dnsEnabled = _prefs.getBool(_dnsEnabledKey) ?? true;
    dnsProvider = _prefs.getString(_dnsProviderKey) ?? 'dns.adguard.com';
    adaptiveThreads = _prefs.getBool(_adaptiveThreadsKey) ?? false;
    autoVerifyChecksum = _prefs.getBool(_autoVerifyChecksumKey) ?? false;

    powerAwareIsolatePool = _prefs.getBool(_powerAwareIsolatePoolKey) ?? true;
    thermalThreadLimiting = _prefs.getBool(_thermalThreadLimitingKey) ?? true;
    jankAutoBatterySaver = _prefs.getBool(_jankAutoBatterySaverKey) ?? true;
    diskWriteBatching = _prefs.getBool(_diskWriteBatchingKey) ?? true;
    powerBandwidthThrottling =
        _prefs.getBool(_powerBandwidthThrottlingKey) ?? true;
    resumeIntegrityCheck = _prefs.getBool(_resumeIntegrityCheckKey) ?? true;

    PowerMonitor.thermalThreadLimitingEnabled = thermalThreadLimiting;
    PowerMonitor.powerBandwidthThrottlingEnabled = powerBandwidthThrottling;

    _loaded = true;
    _instance = this;
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

  /// Returns the effective download speed limit considering bandwidth schedule
  /// windows (including overnight wrap).
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
    _maxDownloads = value;
    await _prefs.setInt(_maxDownloadsKey, value);
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

  Future<void> setEnableProxy(bool value) async {
    enableProxy = value;
    await _prefs.setBool(_enableProxyKey, value);
    notifyListeners();
  }

  Future<void> setProxyAddress(String value) async {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      final validFormat = RegExp(r'^[\w.-]+:\d{1,5}$').hasMatch(trimmed);
      if (!validFormat) {
        _log.warning('Invalid proxy address format: $trimmed');
        return;
      }
      final parts = trimmed.split(':');
      final port = int.tryParse(parts[1]);
      if (port == null || port <= 0 || port > 65535) {
        _log.warning('Invalid proxy port in address: $trimmed');
        return;
      }
    }
    proxyAddress = trimmed;
    await _prefs.setString(_proxyAddressKey, trimmed);
    notifyListeners();
  }

  bool get isProxyAddressValid {
    if (proxyAddress.isEmpty) return true;
    final parts = proxyAddress.split(':');
    if (parts.length != 2) return false;
    final host = parts[0].trim();
    final port = int.tryParse(parts[1].trim());
    if (port == null || port <= 0 || port > 65535 || host.isEmpty) return false;

    // Strict regex validation for RFC-compliant hostnames, IPv4, and IPv6.
    final hostRegExp = RegExp(
      r'^(?:'
      r'(?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.'
      r')*(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])' // Hostname
      r'|'
      r'^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$' // IPv4
      r'|'
      r'^\[?[a-fA-F0-9:]+\]?$', // IPv6 (optional brackets)
    );
    if (!hostRegExp.hasMatch(host)) return false;
    return Uri.tryParse('http://$host') != null && !host.contains(' ');
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
    // P0-2: Require developer mode for SSL bypass
    if (!developerMode) {
      _log.warning('P0-2: Attempted to toggle SSL bypass without developer mode enabled');
      bypassSSL = false;
      _pendingBypassSSLConfirmation = false;
      await _prefs.setBool(_bypassSSLKey, false);
      notifyListeners();
      return;
    }
    if (value) {
      // Require explicit confirmation before enabling — the UI checks this
      // flag and shows a warning dialog; only confirmBypassSSL() enables it.
      _pendingBypassSSLConfirmation = true;
      notifyListeners();
      return;
    }
    bypassSSL = false;
    _pendingBypassSSLConfirmation = false;
    await _prefs.setBool(_bypassSSLKey, false);
    notifyListeners();
  }

  bool _pendingBypassSSLConfirmation = false;
  bool get pendingBypassSSLConfirmation => _pendingBypassSSLConfirmation;

  Future<void> confirmBypassSSL() async {
    if (!developerMode) return;
    _log.warning('P0-2: WARNING: SSL certificate validation has been bypassed by user in Developer Mode');
    bypassSSL = true;
    _pendingBypassSSLConfirmation = false;
    await _prefs.setBool(_bypassSSLKey, true);
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

  Future<void> setTextScaleFactor(double value) async {
    textScaleFactor = value;
    await _prefs.setDouble(_textScaleFactorKey, value);
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
    themeMode = value;
    await _prefs.setString(_themeModeKey, value);
    final resolved = value == 'dark'
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

  /// Whether the current time falls inside the configured quiet-hours window.
  /// Always false when quiet hours are disabled.
  bool isInQuietHoursNow([DateTime? now]) {
    if (!quietHoursEnabled) return false;
    return QuietHours.isInQuietHours(
      start: quietHoursStart,
      end: quietHoursEnd,
      now: now,
    );
  }

  Future<void> setProxyHost(String value) async {
    // Validate host format
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      final hostRegExp = RegExp(
        r'^(?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])(?:\.(?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9]))*$|^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$|^\[?[a-fA-F0-9:]+\]?$',
      );
      if (!hostRegExp.hasMatch(trimmed)) {
        _log.warning('Invalid proxy host format: $trimmed');
        return;
      }
    }
    proxyHost = trimmed;
    await _prefs.setString(_proxyHostKey, trimmed);
    if (proxyHost.isNotEmpty) {
      proxyAddress = '$proxyHost:$proxyPort';
      await _prefs.setString(_proxyAddressKey, proxyAddress);
    }
    notifyListeners();
  }

  Future<void> setProxyPort(int value) async {
    // Clamp port to valid range 1-65535
    proxyPort = value.clamp(1, 65535);
    await _prefs.setInt(_proxyPortKey, proxyPort);
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

  Future<void> setDnsEnabled(bool value) async {
    dnsEnabled = value;
    await _prefs.setBool(_dnsEnabledKey, value);
    notifyListeners();
  }

  Future<void> setDnsProvider(String value) async {
    dnsProvider = value.trim();
    await _prefs.setString(_dnsProviderKey, dnsProvider);
    notifyListeners();
  }

  Future<bool> testProxyConnection(
    String host,
    int port,
    String username,
    String password, {
    bool bypassSSL = false,
  }) async {
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
      if (bypassSSL) {
        client.badCertificateCallback = (cert, host, port) => true;
      }
      final request = await client.getUrl(Uri.parse("https://www.google.com"));
      final response = await request.close();
      return response.statusCode == 200;
    } catch (e) {
      _log.warning('Proxy connection test failed: $e');
      return false;
    } finally {
      client.close(force: true);
    }
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
      _enableProxyKey,
      _proxyAddressKey,
      _bypassSSLKey,
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
      _proxyHostKey,
      _proxyPortKey,
      _proxyUsernameKey,
      _proxyPasswordKey,
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
      _dnsEnabledKey,
      _dnsProviderKey,
    ];
    for (final key in settingsKeys) {
      if (key == _proxyPasswordKey || key == _backendTokenKey) {
        await _secureStorage.delete(key: key);
      } else {
        await _prefs.remove(key);
      }
    }
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
    enableProxy = false;
    proxyAddress = '';
    bypassSSL = false; // secure default — never auto-enable cert bypass
    httpsOnly = false;
    _pendingBypassSSLConfirmation = false;
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
    notificationsEnabled = true;
    quietHoursEnabled = false;
    quietHoursStart = '23:00';
    quietHoursEnd = '07:00';
    proxyHost = '';
    proxyPort = 8080;
    proxyUsername = '';
    proxyPassword = '';
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
    dnsEnabled = true;
    dnsProvider = 'dns.adguard.com';
    resumeIntegrityCheck = true;

    await _prefs.setBool(_isDarkModeKey, _isDarkMode);
    await _prefs.setBool(_classicUiKey, _classicUi);
    await _prefs.setInt(_maxDownloadsKey, _maxDownloads);
    await _prefs.setInt(_defaultThreadCountKey, _defaultThreadCount);
    await _prefs.setBool(_autoStartKey, autoStart);
    await _prefs.setDouble(_speedLimitKey, speedLimitMb);
    await _prefs.setBool(
      _bandwidthScheduleEnabledKey,
      bandwidthScheduleEnabled,
    );
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
    await _prefs.setBool(_enableProxyKey, enableProxy);
    await _prefs.setString(_proxyAddressKey, proxyAddress);
    await _prefs.setBool(_bypassSSLKey, bypassSSL);
    await _prefs.setBool(_httpsOnlyKey, httpsOnly);
    await _prefs.setBool(_reduceVisualsKey, reduceVisuals);
    await _prefs.setDouble(_textScaleFactorKey, textScaleFactor);
    await _prefs.setString(_customUserAgentKey, customUserAgent);
    await _prefs.setInt(_cleanupDaysKey, cleanupDays);
    await _prefs.setBool(_categoryFoldersKey, categoryFolders);
    await _prefs.setBool(_globalTorrentSeedingKey, globalTorrentSeeding);
    await _prefs.setBool(
      _globalTorrentSeedingLimitedKey,
      globalTorrentSeedingLimited,
    );
    await _prefs.setInt(
      _globalTorrentSeedingLimitKbpsKey,
      globalTorrentSeedingLimitKbps,
    );
    await _prefs.setBool(_enableDhtKey, enableDht);
    await _prefs.setBool(_enableUpnpKey, enableUpnp);
    await _prefs.setBool(_forceEncryptKey, forceEncrypt);
    await _prefs.setInt(_torrentConnectionsLimitKey, torrentConnectionsLimit);
    await _prefs.setBool(_incognitoEnabledKey, incognitoEnabled);
    await _prefs.setBool(_desktopModeKey, desktopMode);
    await _prefs.setBool(_pinchToZoomKey, pinchToZoom);
    await _prefs.setBool(_saveBrowserHistoryKey, saveBrowserHistory);
    await _prefs.setBool(_notificationsEnabledKey, notificationsEnabled);
    await _prefs.setBool(_quietHoursEnabledKey, quietHoursEnabled);
    await _prefs.setString(_quietHoursStartKey, quietHoursStart);
    await _prefs.setString(_quietHoursEndKey, quietHoursEnd);
    await _prefs.setString(_proxyHostKey, proxyHost);
    await _prefs.setInt(_proxyPortKey, proxyPort);
    await _prefs.setString(_proxyUsernameKey, proxyUsername);
    await _prefs.setBool(_autoRetryEnabledKey, autoRetryEnabled);
    await _prefs.setInt(_maxRetriesKey, maxRetries);
    await _prefs.setInt(_retryDelaySecondsKey, retryDelaySeconds);
    await _prefs.setString(_searchEngineKey, searchEngine);
    await _prefs.setBool(
      _batteryOptimizationPromptedKey,
      batteryOptimizationPrompted,
    );
    await _prefs.setInt(_maxTotalConnectionsKey, _maxTotalConnections);
    await _prefs.setString(_backendUrlKey, backendUrl);
    await _prefs.setBool(
      _sendBrowserCookiesToBackendKey,
      sendBrowserCookiesToBackend,
    );
    await _prefs.setBool(_useRemoteBackendKey, useRemoteBackend);
    await _prefs.setBool(_dnsEnabledKey, dnsEnabled);
    await _prefs.setString(_dnsProviderKey, dnsProvider);
    if (customDownloadPath != null) {
      await _prefs.setString(_customDownloadPathKey, customDownloadPath!);
    }
    if (proxyPassword.isNotEmpty) {
      await _secureStorage.write(key: _proxyPasswordKey, value: proxyPassword);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
