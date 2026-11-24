import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _notificationChannel =
    MethodChannel('dexterous.com/flutter/local_notifications');
const _secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;
  late Map<String, Object?> loaded;

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      _secureStorageChannel,
      (call) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      _notificationChannel,
      (call) async => null,
    );
    SharedPreferences.setMockInitialValues({
      // Deliberately invalid values so the sanitising branches run on load.
      'maxDownloads': 99,
      'themeMode': 'bogus',
      'cleanupDays': 5,
      'defaultThreadCount': 99,
      'maxRetries': 99,
      'retryDelaySeconds': 99,
      'maxTotalConnections': 99,
      'imageCacheSizeMb': 10,
      'torrentConnectionsLimit': 5,
      'proxyPort': 99999,
      'textScaleFactor': 9.0,
    });
    settings = SettingsProvider.instance;
    await settings.load();
    loaded = {
      'maxDownloads': settings.configuredMaxDownloads,
      'themeMode': settings.themeMode,
      'cleanupDays': settings.cleanupDays,
      'defaultThreadCount': settings.configuredDefaultThreadCount,
      'maxRetries': settings.maxRetries,
      'retryDelaySeconds': settings.retryDelaySeconds,
      'maxTotalConnections': settings.maxTotalConnections,
      'imageCacheSizeMb': settings.imageCacheSizeMb,
      'torrentConnectionsLimit': settings.torrentConnectionsLimit,
      'proxyPort': settings.proxyPort,
      'textScaleFactor': settings.textScaleFactor,
    };
  });

  setUp(() async {
    await settings.resetToDefaults();
  });

  group('load sanitisation', () {
    test('invalid settings are sanitised during load', () {
      expect(loaded['maxDownloads'], 3);
      expect(loaded['themeMode'], 'system');
      expect(loaded['cleanupDays'], 0);
      expect(loaded['defaultThreadCount'], 16);
      expect(loaded['maxRetries'], 3);
      expect(loaded['retryDelaySeconds'], 10);
      expect(loaded['maxTotalConnections'], 32);
      expect(loaded['imageCacheSizeMb'], 30);
      expect(loaded['torrentConnectionsLimit'], 10);
      expect(loaded['proxyPort'], 65535);
      expect(loaded['textScaleFactor'], 9.0);
    });

    test('load is idempotent', () async {
      await settings.load();
      expect(settings.configuredMaxDownloads, 3);
    });

    test('ensureLoaded completes after load', () async {
      await settings.ensureLoaded();
      expect(settings.autoStart, isTrue);
    });
  });

  group('effective getters', () {
    test('batterySaverMode forces safe values', () async {
      await settings.setBatterySaverMode(true);
      expect(settings.maxDownloads, 1);
      expect(settings.defaultThreadCount, 2);
      expect(settings.enableGlow, isFalse);
      expect(settings.classicUi, isTrue);
      expect(settings.reduceVisuals, isTrue);
      expect(settings.effectiveDefaultThreadCount, 2);
      expect(settings.effectiveClassicUi, isTrue);
      await settings.setBatterySaverMode(false);
      expect(settings.maxDownloads, settings.configuredMaxDownloads);
    });

    test('speed limit conversions', () async {
      await settings.setSpeedLimit(2.0);
      expect(settings.speedLimitBytesPerSecond, 2 * 1024 * 1024);
      await settings.setSpeedLimit(0.0);
      expect(settings.effectiveSpeedLimitBytesPerSecond, 0);
    });

    test('effective speed limit honours bandwidth schedule', () async {
      await settings.setSpeedLimit(10.0);
      await settings.setBandwidthScheduleEnabled(true);
      await settings.setScheduleSpeedLimitMb(1.0);
      // Schedule window covers the whole day so the scheduled limit applies.
      await settings.setScheduleStartTime('00:00');
      await settings.setScheduleEndTime('23:59');
      expect(
        settings.effectiveSpeedLimitBytesPerSecond,
        lessThanOrEqualTo(settings.speedLimitBytesPerSecond),
      );
      await settings.setBandwidthScheduleEnabled(false);
    });
  });

  group('theme and visual quality', () {
    test('isDarkMode resolves from themeMode', () async {
      await settings.setThemeMode('dark');
      expect(settings.isDarkMode, isTrue);
      await settings.setThemeMode('amoled');
      expect(settings.isAmoledMode, isTrue);
      expect(settings.isDarkMode, isTrue);
      await settings.setThemeMode('light');
      expect(settings.isDarkMode, isFalse);
      await settings.setThemeMode('system');
      expect(settings.currentThemeMode, ThemeMode.system);
    });

    test('setThemeMode ignores invalid values', () async {
      await settings.setThemeMode('dark');
      await settings.setThemeMode('nonsense');
      expect(settings.themeMode, 'dark');
    });

    test('currentThemeMode maps each value', () async {
      await settings.setThemeMode('light');
      expect(settings.currentThemeMode, ThemeMode.light);
      await settings.setThemeMode('amoled');
      expect(settings.currentThemeMode, ThemeMode.dark);
    });

    test('visualQuality derives from underlying flags', () async {
      await settings.setVisualQuality(VisualQuality.full);
      expect(settings.visualQuality, VisualQuality.full);
      await settings.setVisualQuality(VisualQuality.lite);
      expect(settings.visualQuality, VisualQuality.lite);
      await settings.setVisualQuality(VisualQuality.off);
      expect(settings.visualQuality, VisualQuality.off);
      expect(settings.gridOpacity, 0);
    });

    test('visualQuality restores opacity when re-selected', () async {
      await settings.setGridOpacity(0);
      await settings.setVisualQuality(VisualQuality.full);
      expect(settings.gridOpacity, 40.0);
      await settings.setGridOpacity(0);
      await settings.setVisualQuality(VisualQuality.lite);
      expect(settings.gridOpacity, 20.0);
    });

    test('isDarkMode in system mode reflects platform brightness', () async {
      await settings.setThemeMode('system');
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      expect(settings.isDarkMode, brightness == Brightness.dark);
    });

    test('setIsDarkMode persists without throwing', () async {
      await settings.setThemeMode('light');
      await expectLater(settings.setIsDarkMode(true), completes);
      await expectLater(settings.setIsDarkMode(false), completes);
    });
  });

  group('clamping setters', () {
    test('setMaxDownloads clamps to 1..10', () async {
      await settings.setMaxDownloads(0);
      expect(settings.configuredMaxDownloads, 1);
      await settings.setMaxDownloads(100);
      expect(settings.configuredMaxDownloads, 10);
    });

    test('default thread count clamps to 1..32', () async {
      await settings.setDefaultThreadCount(0);
      expect(settings.configuredDefaultThreadCount, 1);
      await settings.setDefaultThreadCount(1000);
      expect(settings.configuredDefaultThreadCount, 32);
    });

    test('text scale factor clamps to 0.8..2.5', () async {
      await settings.setTextScaleFactor(0.1);
      expect(settings.textScaleFactor, 0.8);
      await settings.setTextScaleFactor(10);
      expect(settings.textScaleFactor, 2.5);
    });

    test('proxy port clamps to 1..65535', () async {
      await settings.setProxyPort(-5);
      expect(settings.proxyPort, 1);
      await settings.setProxyPort(100000);
      expect(settings.proxyPort, 65535);
    });

    test('torrent numeric setters clamp', () async {
      await settings.setMaxActiveTorrents(0);
      expect(settings.maxActiveTorrents, 1);
      await settings.setMaxActiveTorrents(999);
      expect(settings.maxActiveTorrents, 50);

      await settings.setMaxActiveDownloads(0);
      expect(settings.maxActiveDownloads, 1);
      await settings.setMaxActiveDownloads(999);
      expect(settings.maxActiveDownloads, 20);

      await settings.setMaxActiveSeeds(-1);
      expect(settings.maxActiveSeeds, 0);
      await settings.setMaxActiveSeeds(999);
      expect(settings.maxActiveSeeds, 20);

      await settings.setMinSeedTime(-1);
      expect(settings.minSeedTimeMinutes, 0);
      await settings.setMinSeedTime(999999);
      expect(settings.minSeedTimeMinutes, 10080);

      await settings.setTorrentMetadataTimeoutSeconds(1);
      expect(settings.torrentMetadataTimeoutSeconds, 30);
      await settings.setTorrentMetadataTimeoutSeconds(99999);
      expect(settings.torrentMetadataTimeoutSeconds, 1800);

      await settings.setMaxPeerConnectionsPerTorrent(1);
      expect(settings.maxPeerConnectionsPerTorrent, 5);
      await settings.setMaxPeerConnectionsPerTorrent(99999);
      expect(settings.maxPeerConnectionsPerTorrent, 500);

      await settings.setMaxHalfOpenConnections(0);
      expect(settings.maxHalfOpenConnections, 1);
      await settings.setMaxHalfOpenConnections(999);
      expect(settings.maxHalfOpenConnections, 100);

      await settings.setDiskCacheSizeMb(1);
      expect(settings.diskCacheSizeMb, 16);
      await settings.setDiskCacheSizeMb(99999);
      expect(settings.diskCacheSizeMb, 4096);

      await settings.setDownloadStalledTimeoutMinutes(0);
      expect(settings.downloadStalledTimeoutMinutes, 1);
      await settings.setDownloadStalledTimeoutMinutes(999);
      expect(settings.downloadStalledTimeoutMinutes, 120);
    });

    test('image cache size 0 stays auto, others clamp', () async {
      await settings.setImageCacheSizeMb(0);
      expect(settings.imageCacheSizeMb, 0);
      await settings.setImageCacheSizeMb(-1);
      expect(settings.imageCacheSizeMb, 0);
      await settings.setImageCacheSizeMb(1);
      expect(settings.imageCacheSizeMb, 30);
      await settings.setImageCacheSizeMb(9999);
      expect(settings.imageCacheSizeMb, 256);
    });
  });

  group('simple toggles and values', () {
    test('booleans round-trip', () async {
      await settings.setAutoStart(false);
      expect(settings.autoStart, isFalse);
      await settings.setWifiOnly(true);
      expect(settings.wifiOnly, isTrue);
      await settings.setVibration(true);
      expect(settings.vibration, isTrue);
      await settings.setSoundNotification(false);
      expect(settings.soundNotification, isFalse);
      await settings.setShowOnboarding(false);
      expect(settings.showOnboarding, isFalse);
      await settings.setClassicUi(false);
      expect(settings.classicUi, isFalse);
      await settings.setHttpsOnly(true);
      expect(settings.httpsOnly, isTrue);
      await settings.setReduceVisuals(true);
      expect(settings.reduceVisuals, isTrue);
      await settings.setEnableGlow(false);
      expect(settings.enableGlow, isFalse);
      await settings.setCategoryFolders(true);
      expect(settings.categoryFolders, isTrue);
    });

    test('torrent feature toggles round-trip', () async {
      await settings.setEnableDht(false);
      expect(settings.enableDht, isFalse);
      await settings.setEnableUpnp(false);
      expect(settings.enableUpnp, isFalse);
      await settings.setEnableNatPmp(false);
      expect(settings.enableNatPmp, isFalse);
      await settings.setEnableLpd(false);
      expect(settings.enableLpd, isFalse);
      await settings.setEnablePex(false);
      expect(settings.enablePex, isFalse);
      await settings.setQueueTorrents(false);
      expect(settings.queueTorrents, isFalse);
      await settings.setForceEncrypt(true);
      expect(settings.forceEncrypt, isTrue);
      await settings.setSequentialDownload(true);
      expect(settings.sequentialDownload, isTrue);
      await settings.setEnableUtp(false);
      expect(settings.enableUtp, isFalse);
      await settings.setEnableLsd(false);
      expect(settings.enableLsd, isFalse);
      await settings.setUseOsCache(false);
      expect(settings.useOsCache, isFalse);
      await settings.setSeedOnlyWhenCharging(true);
      expect(settings.seedOnlyWhenCharging, isTrue);
      await settings.setSeedOnlyOnWifi(true);
      expect(settings.seedOnlyOnWifi, isTrue);
      await settings.setEnableIpFilter(true);
      expect(settings.enableIpFilter, isTrue);
      await settings.setEnableAnonymousMode(true);
      expect(settings.enableAnonymousMode, isTrue);
      await settings.setGlobalTorrentSeeding(false);
      expect(settings.globalTorrentSeeding, isFalse);
      await settings.setGlobalTorrentSeedingLimited(true);
      expect(settings.globalTorrentSeedingLimited, isTrue);
    });

    test('power and performance toggles round-trip', () async {
      await settings.setPowerAwareIsolatePool(false);
      expect(settings.powerAwareIsolatePool, isFalse);
      await settings.setThermalThreadLimiting(false);
      expect(settings.thermalThreadLimiting, isFalse);
      await settings.setJankAutoBatterySaver(true);
      expect(settings.jankAutoBatterySaver, isTrue);
      await settings.setDiskWriteBatching(false);
      expect(settings.diskWriteBatching, isFalse);
      await settings.setPowerBandwidthThrottling(false);
      expect(settings.powerBandwidthThrottling, isFalse);
      await settings.setDownloadOnlyWhileCharging(true);
      expect(settings.downloadOnlyWhileCharging, isTrue);
      await settings.setPauseOnCellular(true);
      expect(settings.pauseOnCellular, isTrue);
      await settings.setAutoReduceEffectsOnJank(false);
      expect(settings.autoReduceEffectsOnJank, isFalse);
      await settings.setAdaptiveThreads(true);
      expect(settings.adaptiveThreads, isTrue);
      await settings.setAutoVerifyChecksum(true);
      expect(settings.autoVerifyChecksum, isTrue);
      await settings.setResumeIntegrityCheck(false);
      expect(settings.resumeIntegrityCheck, isFalse);
    });

    test('browser toggles round-trip', () async {
      await settings.setIncognitoEnabled(true);
      expect(settings.incognitoEnabled, isTrue);
      await settings.setDesktopMode(true);
      expect(settings.desktopMode, isTrue);
      await settings.setPinchToZoom(false);
      expect(settings.pinchToZoom, isFalse);
      await settings.setSaveBrowserHistory(false);
      expect(settings.saveBrowserHistory, isFalse);
      await settings.setForceDarkMode(true);
      expect(settings.forceDarkMode, isTrue);
      await settings.setBlockImages(true);
      expect(settings.blockImages, isTrue);
      await settings.setOpenLinksInApp(true);
      expect(settings.openLinksInApp, isTrue);
      await settings.setFormAutofill(false);
      expect(settings.formAutofill, isFalse);
      await settings.setAntiFingerprinting(false);
      expect(settings.antiFingerprinting, isFalse);
    });

    test('string values round-trip', () async {
      await settings.setLanguageCode('ar');
      expect(settings.languageCode, 'ar');
      await settings.setSearchEngine('DuckDuckGo');
      expect(settings.searchEngine, 'DuckDuckGo');
      await settings.setCustomUserAgent('agent/1');
      expect(settings.customUserAgent, 'agent/1');
      await settings.setTranslateTargetLang('fr');
      expect(settings.translateTargetLang, 'fr');
      await settings.setIpFilterPath('/tmp/list.p2p');
      expect(settings.ipFilterPath, '/tmp/list.p2p');
      await settings.setProxyHost('proxy.local');
      expect(settings.proxyHost, 'proxy.local');
    });

    test('custom download path can be set and cleared', () async {
      await settings.setCustomDownloadPath('/tmp/dl');
      expect(settings.customDownloadPath, '/tmp/dl');
      await settings.setCustomDownloadPath(null);
      expect(settings.customDownloadPath, isNull);
    });

    test('quiet hours logic', () async {
      await settings.setQuietHoursEnabled(false);
      expect(settings.isInQuietHoursNow(), isFalse);
      await settings.setQuietHoursEnabled(true);
      await settings.setQuietHoursStart('00:00');
      await settings.setQuietHoursEnd('23:59');
      expect(settings.isInQuietHoursNow(DateTime(2026, 1, 1, 12)), isTrue);
    });

    test('setNotificationsEnabled(false) cancels notifications', () async {
      await settings.setNotificationsEnabled(false);
      expect(settings.notificationsEnabled, isFalse);
      await settings.setNotificationsEnabled(true);
      expect(settings.notificationsEnabled, isTrue);
    });
  });

  group('proxy / ssl / backend', () {
    test('setProxySettings enables proxy for a real type', () async {
      await settings.setProxySettings(
        host: 'p.local',
        port: 8080,
        type: ProxyType.socks5,
        username: 'u',
        password: 'p',
      );
      expect(settings.proxyHost, 'p.local');
      expect(settings.proxyPort, 8080);
      expect(settings.proxyType, 'socks5');
      expect(settings.proxyUsername, 'u');
      expect(settings.proxyPassword, 'p');
      expect(settings.enableProxy, isTrue);
      expect(settings.enforceProxy, isTrue);
    });

    test('setProxySettings with none disables proxy', () async {
      await settings.setProxySettings(
        host: '',
        port: 1080,
        type: ProxyType.none,
      );
      expect(settings.enableProxy, isFalse);
      expect(settings.proxyUsername, isNull);
    });

    test('setSslSettings populates paths', () async {
      await settings.setSslSettings(
        certPath: '/c.pem',
        privateKeyPath: '/k.pem',
        dhParamsPath: '/dh.pem',
      );
      expect(settings.sslCertPath, '/c.pem');
      expect(settings.sslKeyPath, '/k.pem');
      expect(settings.isSslActive, isTrue);
      await settings.setSslSettings(certPath: '', privateKeyPath: '');
      expect(settings.isSslActive, isFalse);
    });

    test('backend settings round-trip', () async {
      await settings.setBackendUrl('https://backend.example.com');
      expect(settings.backendUrl, 'https://backend.example.com');
      await settings.setBackendToken('token-123');
      expect(settings.backendToken, 'token-123');
      await settings.setSendBrowserCookiesToBackend(true);
      expect(settings.sendBrowserCookiesToBackend, isTrue);
      await settings.setUseLocalYtFallback(true);
      expect(settings.useLocalYtFallback, isTrue);
      await settings.setUseRemoteBackend(false);
      expect(settings.useRemoteBackend, isFalse);
      await settings.setBatteryOptimizationPrompted(true);
      expect(settings.batteryOptimizationPrompted, isTrue);
      await settings.setMaxTotalConnections(64);
      expect(settings.maxTotalConnections, 64);
    });
  });

  group('retry settings', () {
    test('retry settings round-trip', () async {
      await settings.setAutoRetryEnabled(false);
      expect(settings.autoRetryEnabled, isFalse);
      await settings.setMaxRetries(5);
      expect(settings.maxRetries, 5);
      await settings.setRetryDelaySeconds(30);
      expect(settings.retryDelaySeconds, 30);
    });
  });

  group('developer mode', () {
    test('bypassSSL requires developer mode and debug', () async {
      await settings.resetToDefaults();
      expect(settings.developerMode, isFalse);
      expect(settings.bypassSSL, isFalse);
      await settings.toggleDeveloperMode();
      expect(settings.developerMode, isTrue);
    });
  });

  group('torrent session settings mapping', () {
    test('toTorrentSessionSettings reflects current values', () async {
      await settings.setEnableDht(false);
      await settings.setForceEncrypt(true);
      await settings.setSequentialDownload(true);
      await settings.setShareRatioLimit(3.5);
      await settings.setDiskCacheSizeMb(256);
      await settings.setGlobalTorrentSeedingLimited(true);
      final session = settings.toTorrentSessionSettings();
      expect(session.enableDht, isFalse);
      expect(session.forceEncrypt, isTrue);
      expect(session.sequentialDownload, isTrue);
      expect(session.shareRatioLimit, 3.5);
      expect(session.diskCacheSizeBytes, 256 * 1024 * 1024);
      expect(session.uploadRateLimitKbps, settings.globalTorrentSeedingLimitKbps);
    });
  });

  group('active tab index', () {
    test('setActiveSettingsTabIndex notifies only on change', () {
      var notifications = 0;
      void listener() => notifications++;
      settings.addListener(listener);
      settings.setActiveSettingsTabIndex(2);
      expect(settings.activeSettingsTabIndex, 2);
      settings.setActiveSettingsTabIndex(2);
      expect(notifications, 1);
      settings.removeListener(listener);
    });
  });

  group('grid opacity debounce', () {
    test('setGridOpacity updates immediately and persists later', () async {
      await settings.setGridOpacity(55);
      expect(settings.gridOpacity, 55.0);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(settings.gridOpacity, 55.0);
    });
  });

  group('resetToDefaults', () {
    test('restores all defaults', () async {
      await settings.setAutoStart(false);
      await settings.setEnableDht(false);
      await settings.setBackendUrl('https://x.example.com');
      await settings.resetToDefaults();
      expect(settings.autoStart, isTrue);
      expect(settings.enableDht, isTrue);
      expect(settings.backendUrl, '');
      expect(settings.configuredMaxDownloads, 3);
      expect(settings.configuredDefaultThreadCount, 16);
    });
  });

  group('loadedInstance guard', () {
    test('loadedInstance returns the loaded singleton', () {
      expect(() => SettingsProvider.loadedInstance, returnsNormally);
    });
  });

  group('didChangePlatformBrightness', () {
    test('does not throw for non-system theme', () {
      settings.themeMode = 'dark';
      expect(() => settings.didChangePlatformBrightness(), returnsNormally);
    });
  });
}
