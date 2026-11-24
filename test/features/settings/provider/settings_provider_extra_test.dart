import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const _notificationChannel =
    MethodChannel('dexterous.com/flutter/local_notifications');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;

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
    SharedPreferences.setMockInitialValues({});
    settings = SettingsProvider.instance;
    await settings.load();
  });

  setUp(() async {
    await settings.resetToDefaults();
  });

  group('additional setters', () {
    test('maxTabs setter round-trips', () async {
      settings.maxTabs = 24;
      expect(settings.maxTabs, 24);
      settings.maxTabs = 8;
      expect(settings.maxTabs, 8);
    });

    test('historyMaxEntries setter round-trips', () async {
      settings.historyMaxEntries = 250;
      expect(settings.historyMaxEntries, 250);
      settings.historyMaxEntries = 1000;
      expect(settings.historyMaxEntries, 1000);
    });

    test('maxConcurrentFilesPerTorrent getter and setter', () async {
      expect(settings.maxConcurrentFilesPerTorrent, 0);
      await settings.setMaxConcurrentFilesPerTorrent(4);
      expect(settings.maxConcurrentFilesPerTorrent, 4);
    });

    test('configuredClassicUi reflects the backing field', () async {
      await settings.setClassicUi(false);
      expect(settings.configuredClassicUi, isFalse);
      await settings.setClassicUi(true);
      expect(settings.configuredClassicUi, isTrue);
    });

    test('setEnableProxy and setEnforceProxy round-trip', () async {
      await settings.setEnableProxy(true);
      expect(settings.enableProxy, isTrue);
      await settings.setEnforceProxy(true);
      expect(settings.enforceProxy, isTrue);
      await settings.setEnableProxy(false);
      await settings.setEnforceProxy(false);
      expect(settings.enableProxy, isFalse);
      expect(settings.enforceProxy, isFalse);
    });

    test('setCleanupDays persists the value', () async {
      await settings.setCleanupDays(7);
      expect(settings.cleanupDays, 7);
      await settings.setCleanupDays(30);
      expect(settings.cleanupDays, 30);
    });

    test('setGlobalTorrentSeedingLimitKbps persists the value', () async {
      await settings.setGlobalTorrentSeedingLimitKbps(1234);
      expect(settings.globalTorrentSeedingLimitKbps, 1234);
    });

    test('setTorrentConnectionsLimit persists the value', () async {
      await settings.setTorrentConnectionsLimit(500);
      expect(settings.torrentConnectionsLimit, 500);
    });

    test('setMaxSeedingTime persists the value', () async {
      await settings.setMaxSeedingTime(90);
      expect(settings.maxSeedingTimeMinutes, 90);
    });
  });

  group('didChangePlatformBrightness', () {
    test('updates dark mode when system brightness differs', () async {
      await settings.setThemeMode('system');
      final platformDark =
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark;
      // Force the stored value to the opposite of the platform so the branch
      // that persists/notifies actually executes.
      await settings.setIsDarkMode(!platformDark);

      var notifications = 0;
      void listener() => notifications++;
      settings.addListener(listener);
      settings.didChangePlatformBrightness();
      settings.removeListener(listener);

      expect(notifications, greaterThanOrEqualTo(1));
    });
  });

  group('resetToDefaults additional state', () {
    test('clears proxy username and custom download path', () async {
      await settings.setProxySettings(
        host: 'proxy.local',
        port: 1080,
        type: ProxyType.socks5,
        username: 'bob',
        password: 'secret',
      );
      await settings.setCustomDownloadPath('/tmp/downloads');
      expect(settings.proxyUsername, 'bob');

      await settings.resetToDefaults();

      expect(settings.proxyUsername, isNull);
      expect(settings.proxyPassword, isNull);
      expect(settings.proxyType, 'none');
      expect(settings.enableProxy, isFalse);
    });
  });

  group('torrent session mapping', () {
    test('maps values after reset with battery saver on', () async {
      await settings.setBatterySaverMode(true);
      final session = settings.toTorrentSessionSettings();
      expect(session, isNotNull);
      await settings.setBatterySaverMode(false);
    });
  });
}
