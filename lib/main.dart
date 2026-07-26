import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'core/utils/constants.dart';
import 'core/services/torrent_service.dart';
import 'core/app_theme.dart';
import 'core/services/background_service.dart';
import 'core/services/database_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/single_instance_service.dart';
import 'core/services/xdm_backend_client.dart';
import 'core/services/youtube_service.dart';
import 'features/downloads/provider/download_provider.dart';
import 'features/settings/provider/settings_provider.dart';
import 'features/browser/services/ad_blocker.dart';
import 'features/onboarding/screens/onboarding_screen.dart';
import 'shared/widgets/main_navigation_container.dart';
import 'shared/widgets/share_intent_screen.dart';

Future<void> main(List<String> args) async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        debugPrint('FlutterError: ${details.exception}');
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        debugPrint('Platform error: $error\n$stack');
        return true;
      };
      try {
        final isPrimary = await SingleInstanceService().initialize(args);
        if (!isPrimary) {
          // A running primary instance was notified, exit this process cleanly.
          // ignore: avoid_slow_async_io
          exit(0);
        }

        await XdmBackendClient.loadApiKey();

        // Torrent engine is only needed for torrent downloads — lazy-init on
        // first use rather than blocking app startup.
        if (TorrentService.isSupported) {
          // ignore: unawaited_futures
          Future.microtask(() => TorrentService.init());
        }

        await Hive.initFlutter();

        final databaseService = DatabaseService();
        await databaseService.init();

        final settingsProvider = SettingsProvider.instance;
        await settingsProvider.load();

        // AdBlocker is only needed in the browser — defer but start after
        // settings are loaded so we can detect first-launch state.
        // ignore: unawaited_futures
        AdBlocker.initialize(forceUpdate: settingsProvider.showOnboarding);

        XdmBackendClient().refreshConfig();

        await YoutubeService.init();

        final notificationService = NotificationService();
        await notificationService.init(requestPermission: false);

        await BackgroundService.initialize();

        final packageInfo = await PackageInfo.fromPlatform();
        kAppVersion = packageInfo.version;

        final downloadProvider = DownloadProvider(
          databaseService: databaseService,
          settingsProvider: settingsProvider,
          notificationService: notificationService,
        );
        await downloadProvider.load();

        runApp(
          DmxApp(
            databaseService: databaseService,
            settingsProvider: settingsProvider,
            downloadProvider: downloadProvider,
            initialUrl: SingleInstanceService().initialUrl,
          ),
        );
      } catch (e, stack) {
        debugPrint('Initialization error: $e\n$stack');
        runApp(ErrorApp(error: e.toString()));
      }
    },
    (error, stack) {
      debugPrint('Uncaught zone error: $error\n$stack');
    },
  );
}

class ErrorApp extends StatelessWidget {
  final String error;
  const ErrorApp({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XDM Error',
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Colors.redAccent,
                  size: 64,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Initialization Failed',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  error,
                  style: const TextStyle(color: Colors.redAccent),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DmxApp extends StatelessWidget {
  const DmxApp({
    super.key,
    required this.databaseService,
    required this.settingsProvider,
    required this.downloadProvider,
    this.initialUrl,
  });

  final DatabaseService databaseService;
  final SettingsProvider settingsProvider;
  final DownloadProvider downloadProvider;
  final String? initialUrl;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<DatabaseService>.value(value: databaseService),
        ChangeNotifierProvider<SettingsProvider>.value(value: settingsProvider),
        ChangeNotifierProvider<DownloadProvider>.value(value: downloadProvider),
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, child) {
          final isDark = settings.isDarkMode;
          return MaterialApp(
            title: 'XDM - Download Manager X',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: settings.currentThemeMode,
            locale: Locale(settings.languageCode),
            home: settings.showOnboarding
                ? const OnboardingScreen()
                : (initialUrl != null && initialUrl!.trim().isNotEmpty)
                    ? ShareLaunchScreen(url: initialUrl!)
                    : const MainNavigationContainer(),
            builder: (context, child) {
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: SystemUiOverlayStyle(
                  statusBarColor: Colors.transparent,
                  statusBarIconBrightness: isDark
                      ? Brightness.light
                      : Brightness.dark,
                  statusBarBrightness: isDark
                      ? Brightness.dark
                      : Brightness.light,
                  systemNavigationBarColor: isDark
                      ? AppTheme.background
                      : AppTheme.lightBackground,
                  systemNavigationBarIconBrightness: isDark
                      ? Brightness.light
                      : Brightness.dark,
                ),
                child: child!,
              );
            },
          );
        },
      ),
    );
  }
}
