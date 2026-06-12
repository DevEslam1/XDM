import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'core/services/torrent_service.dart';
import 'core/app_theme.dart';
import 'core/services/background_service.dart';
import 'core/services/database_service.dart';
import 'core/services/notification_service.dart';
import 'features/downloads/provider/download_provider.dart';
import 'features/settings/provider/settings_provider.dart';
import 'features/browser/services/ad_blocker.dart';
import 'features/onboarding/screens/splash_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AdBlocker.initialize();
  if (TorrentService.isSupported) {
    await TorrentService.init();
  }
  await Hive.initFlutter();

  final databaseService = DatabaseService();
  await databaseService.init();

  final settingsProvider = SettingsProvider();
  await settingsProvider.load();

  final notificationService = NotificationService();
  await notificationService.init();

  await BackgroundService.initialize();

  final downloadProvider = DownloadProvider(
    databaseService: databaseService,
    settingsProvider: settingsProvider,
    notificationService: notificationService,
  );
  await downloadProvider.load();

  runApp(
    DmxApp(
      settingsProvider: settingsProvider,
      downloadProvider: downloadProvider,
    ),
  );
}

class DmxApp extends StatelessWidget {
  const DmxApp({
    super.key,
    required this.settingsProvider,
    required this.downloadProvider,
  });

  final SettingsProvider settingsProvider;
  final DownloadProvider downloadProvider;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsProvider>.value(value: settingsProvider),
        ChangeNotifierProvider<DownloadProvider>.value(value: downloadProvider),
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, child) {
          return MaterialApp(
            title: 'XDM - Download Manager X',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: settings.currentThemeMode,
            locale: Locale(settings.languageCode),
            home: const SplashScreen(),
          );
        },
      ),
    );
  }
}
