import 'package:dmx/core/di/injection.dart';
import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:dmx/features/details/widgets/torrent_advanced_settings_sheet.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    setupTestPluginMocks();
    SharedPreferences.setMockInitialValues({});
    if (getIt.isRegistered<ITorrentService>()) {
      getIt.unregister<ITorrentService>();
    }
    getIt.registerLazySingleton<ITorrentService>(() => TorrentServiceImpl());
  });

  group('ProxyType Model Tests', () {
    test('parses from strings correctly', () {
      expect(ProxyType.fromString('socks5'), equals(ProxyType.socks5));
      expect(ProxyType.fromString('SOCKS5'), equals(ProxyType.socks5));
      expect(ProxyType.fromString('http'), equals(ProxyType.http));
      expect(ProxyType.fromString('https'), equals(ProxyType.http));
      expect(ProxyType.fromString('none'), equals(ProxyType.none));
      expect(ProxyType.fromString(null), equals(ProxyType.none));
      expect(ProxyType.fromString('invalid'), equals(ProxyType.none));
    });

    test('displayName returns clear label', () {
      expect(ProxyType.none.displayName, contains('None'));
      expect(ProxyType.socks5.displayName, equals('SOCKS5'));
      expect(ProxyType.http.displayName, equals('HTTP'));
    });
  });

  group('Web Seeds Management Tests', () {
    test('adds, retrieves, and removes web seeds for torrents', () {
      const torrentId = 42;
      const url1 = 'https://mirror1.example.com/file.iso';
      const url2 = 'https://mirror2.example.com/file.iso';

      TorrentService.addWebSeed(torrentId, url1);
      TorrentService.addWebSeed(torrentId, url2);

      final seeds = TorrentService.getWebSeeds(torrentId);
      expect(seeds, contains(url1));
      expect(seeds, contains(url2));
      expect(seeds.length, equals(2));

      TorrentService.removeWebSeed(torrentId, url1);
      final remaining = TorrentService.getWebSeeds(torrentId);
      expect(remaining, isNot(contains(url1)));
      expect(remaining, contains(url2));
      expect(remaining.length, equals(1));
    });
  });

  group('TorrentService Proxy and SSL Invocation Tests', () {
    test('setProxy and setSslCertificate complete safely without throwing', () async {
      await expectLater(
        TorrentService.setProxy(
          host: '127.0.0.1',
          port: 9050,
          type: ProxyType.socks5,
          username: 'user',
          password: 'pwd',
        ),
        completes,
      );

      await expectLater(
        TorrentService.setSslCertificate(
          certPath: '/path/to/cert.pem',
          privateKeyPath: '/path/to/key.pem',
          dhParamsPath: '/path/to/dh.pem',
        ),
        completes,
      );
    });
  });

  group('SettingsProvider Proxy & SSL Persistence Tests', () {
    test('persists and updates proxy and SSL settings', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider.instance;
      await settings.load();

      await settings.setProxySettings(
        host: '10.0.0.1',
        port: 8080,
        type: ProxyType.http,
        username: 'myuser',
        password: 'mypassword',
      );

      expect(settings.proxyHost, equals('10.0.0.1'));
      expect(settings.proxyPort, equals(8080));
      expect(settings.proxyType, equals('http'));
      expect(settings.proxyUsername, equals('myuser'));
      expect(settings.proxyPassword, equals('mypassword'));
      expect(settings.enableProxy, isTrue);

      await settings.setSslSettings(
        certPath: '/certs/client.pem',
        privateKeyPath: '/certs/client.key',
      );

      expect(settings.sslCertPath, equals('/certs/client.pem'));
      expect(settings.sslKeyPath, equals('/certs/client.key'));
      expect(settings.isSslActive, isTrue);
    });
  });

  group('TorrentAdvancedSettingsSheet Widget Tests', () {
    testWidgets('renders all 3 sections: Web Seeds, Proxy, and SSL',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider.instance;
      await settings.load();

      final provider = createMockDownloadProvider();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
            ChangeNotifierProvider<DownloadProvider>.value(value: provider),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: TorrentAdvancedSettingsSheet(torrentId: 99),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Advanced Torrent Controls'), findsOneWidget);
      expect(find.text('Web Seeds (HTTP/FTP)'), findsOneWidget);
      expect(find.text('Proxy Configuration (Session-level)'), findsOneWidget);
      expect(find.text('SSL / Private Trackers (Session-level)'), findsOneWidget);
      expect(find.text('Add'), findsOneWidget);
      expect(find.text('Apply Proxy Settings'), findsOneWidget);
      expect(find.text('Apply SSL Certificates'), findsOneWidget);
    });
  });
}
