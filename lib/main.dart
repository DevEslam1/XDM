import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'core/utils/url_utils.dart';
import 'core/utils/constants.dart';
import 'core/services/torrent_service.dart';
import 'core/services/torrent_resume_store.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'core/app_theme.dart';
import 'core/services/background_service.dart';
import 'core/services/database_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/single_instance_service.dart';
import 'core/services/xdm_backend_client.dart';
import 'core/services/youtube_service.dart';
import 'core/services/remote_api_service.dart';
import 'features/downloads/provider/download_provider.dart';
import 'features/settings/provider/settings_provider.dart';
import 'features/onboarding/screens/onboarding_screen.dart';
import 'shared/widgets/main_navigation_container.dart';
import 'shared/widgets/share_intent_screen.dart';

Future<void> main(List<String> args) async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // ── Logging setup (unchanged) ──
      Logger.root.level = kDebugMode ? Level.ALL : Level.WARNING;
      Logger.root.onRecord.listen((record) {
        debugPrint('[${record.level.name}] ${record.loggerName}: ${record.message}');
        if (record.error != null) debugPrint('  Error: ${record.error}');
      });
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        debugPrint('FlutterError: ${details.exception}');
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        debugPrint('Platform error: $error\n$stack');
        return true;
      };

      try {
        // ── PHASE 1: Gate (must be first — exits if another instance owns the port) ──
        final isPrimary = await SingleInstanceService().initialize(args);
        if (!isPrimary) exit(0);

        // ── PHASE 2: Parallel fast inits (no secure storage, no native) ──
        await Future.wait([
          PackageInfo.fromPlatform().then((info) => setAppVersion(info.version)),
        ]);

        // ── PHASE 3: Settings (required for theme before runApp) ──
        final settingsProvider = SettingsProvider.instance;
        await settingsProvider.load();
        XdmBackendClient().refreshConfig();

        // ── PHASE 4: Build providers (no blocking I/O) and show UI immediately ──
        final databaseService = DatabaseService();
        final notificationService = NotificationService();
        final downloadProvider = DownloadProvider(
          databaseService: databaseService,
          settingsProvider: settingsProvider,
          notificationService: notificationService,
        );

        // Fast share-intent detection (bounded by 150ms timeout)
        String? initialUrl = SingleInstanceService().initialUrl;
        if (initialUrl == null || initialUrl.trim().isEmpty) {
          try {
            final sharedFiles = await ReceiveSharingIntent.instance
                .getInitialMedia()
                .timeout(const Duration(milliseconds: 150));
            if (sharedFiles.isNotEmpty) {
              final raw = sharedFiles.first.path.trim();
              final extracted = extractUrlFromText(raw) ?? raw;
              if (isHttpUrl(extracted) ||
                  isMagnetUrl(extracted) ||
                  isTorrentFileUrl(extracted)) {
                initialUrl = extracted;
              }
            }
          } catch (_) {}
        }

        runApp(
          DmxApp(
            databaseService: databaseService,
            settingsProvider: settingsProvider,
            downloadProvider: downloadProvider,
            initialUrl: initialUrl,
          ),
        );

        // ── PHASE 5: Heavy init AFTER first frame ──
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          try {
            // DB + torrent native init in parallel.
            // Torrent MUST be ready before load() pumps torrent tasks.
            final initFutures = <Future<void>>[databaseService.init()];
            if (TorrentService.isSupported) {
              initFutures.add(() async {
                try {
                  await TorrentResumeStore.init();
                  await TorrentService.init();
                  debugPrint('Torrent service initialized successfully');
                } catch (e, s) {
                  debugPrint('Torrent init failed, continuing without torrent support: $e');
                  Logger('main').severe('Torrent init failed', e, s);
                }
              }());
            }
            await Future.wait(initFutures);

            // Load tasks (triggers pumpQueue) — UI is already up; list populates now.
            await downloadProvider.load();
          } catch (e, s) {
            debugPrint('Deferred init failed: $e\n$s');
          }

          // Non-critical services — independent, fire-and-forget.
          unawaited(_initNonCriticalServices(downloadProvider, notificationService));
        });
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

Future<void> _initNonCriticalServices(
  DownloadProvider downloadProvider,
  NotificationService notificationService,
) async {
  try { await XdmBackendClient.loadApiKey(); }
  catch (e) { debugPrint('API key load failed: $e'); }

  try { await notificationService.init(requestPermission: false); }
  catch (e) { debugPrint('Notification init failed: $e'); }

  try { await BackgroundService.initialize(); }
  catch (e) { debugPrint('Background service init failed: $e'); }

  try { await YoutubeService.init(); }
  catch (e) { debugPrint('YouTube init failed: $e'); }

  unawaited(
    RemoteApiService.start(
      getTasks: () async =>
          downloadProvider.tasks.map((t) => t.toMap()).toList(),
      pauseTask: (id) => downloadProvider.pauseTask(id),
      resumeTask: (id) => downloadProvider.resumeTask(id),
      deleteTask: (id) => downloadProvider.deleteTask(id),
    ),
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
