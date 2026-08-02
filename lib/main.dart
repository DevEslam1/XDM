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
import 'core/services/crash_reporting_service.dart';
import 'core/services/logging_service.dart';
import 'core/services/mirror_health_store.dart';
import 'core/services/background_service.dart';
import 'core/services/database_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/performance_monitor.dart';
import 'core/services/single_instance_service.dart';
import 'core/services/xdm_backend_client.dart';
import 'core/services/youtube_service.dart';
import 'core/services/remote_api_service.dart';
import 'features/downloads/provider/download_provider.dart';
import 'features/settings/provider/settings_provider.dart';
import 'features/onboarding/screens/onboarding_screen.dart';
import 'features/onboarding/screens/permission_request_screen.dart';
import 'shared/widgets/main_navigation_container.dart';
import 'shared/widgets/share_intent_screen.dart';
import 'shared/accessibility/xdm_text_scaler.dart';

Future<void> main(List<String> args) async {
  CrashReportingService.runWithErrorCapture(() async {
    // ── Logging: must be first so all subsequent init can log ──
    LoggingService.init();
    CrashReportingService.captureFlutterErrors();

    WidgetsFlutterBinding.ensureInitialized();

    // ── Image cache sizing ──
    // Bound the decoded-image cache so large thumbnails/artwork don't consume
    // all available memory on low-end devices. Defaults are ~100 MB / 1000
    // images; we keep a slightly conservative budget and rely on Flutter's
    // built-in memory-pressure clearing for the rest.
    PaintingBinding.instance.imageCache
      ..maximumSizeBytes = 80 * 1024 * 1024
      ..maximumSize = 1000;

    // ── Frame performance monitoring (UI-jank diagnostics) ──
    PerformanceMonitor.instance.start();

    // Custom error widget builder for better UX
    ErrorWidget.builder = (FlutterErrorDetails errorDetails) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 64, color: Colors.red),
                  const SizedBox(height: 16),
                  const Text(
                    'Something went wrong',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    kDebugMode
                        ? errorDetails.toString()
                        : 'An unexpected error occurred',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => exit(0),
                    child: const Text('Restart App'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('Platform error: $error\n$stack');
      unawaited(
        CrashReportingService.recordError(
          error,
          stack,
          hint: 'PlatformDispatcher',
        ).catchError((e) {}),
      );
      return false;
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
      WidgetsBinding.instance.addObserver(_AppLifecycleObserver());

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
                debugPrint(
                  'Torrent init failed, continuing without torrent support: $e',
                );
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
        unawaited(
          _initNonCriticalServices(
            downloadProvider,
            notificationService,
          ).catchError((e) {}),
        );
      });
    } catch (e, stack) {
      debugPrint('Initialization error: $e\n$stack');
      runApp(ErrorApp(error: e.toString()));
    }
  });
}

Future<void> _initNonCriticalServices(
  DownloadProvider downloadProvider,
  NotificationService notificationService,
) async {
  try {
    await MirrorHealthStore.init();
  } catch (e) {
    debugPrint('Mirror health store init failed: $e');
  }

  try {
    await XdmBackendClient.loadApiKey();
  } catch (e) {
    debugPrint('API key load failed: $e');
  }

  try {
    await notificationService.init(requestPermission: false);
  } catch (e) {
    debugPrint('Notification init failed: $e');
  }

  try {
    await BackgroundService.initialize();
  } catch (e) {
    debugPrint('Background service init failed: $e');
  }

  try {
    await YoutubeService.init();
  } catch (e) {
    debugPrint('YouTube init failed: $e');
  }

  unawaited(
    RemoteApiService.start(
      getTasks: () async =>
          downloadProvider.tasks.map((t) => t.toMap()).toList(),
      pauseTask: (id) => downloadProvider.pauseTask(id),
      resumeTask: (id) => downloadProvider.resumeTask(id),
      deleteTask: (id) => downloadProvider.deleteTask(id),
    ).catchError((e) {
      debugPrint('RemoteApiService.start failed: $e');
    }),
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
                // Android: block app usage until a download folder is chosen,
                // otherwise downloads silently land in Android/data.
                : (!kIsWeb &&
                      Platform.isAndroid &&
                      (settings.customDownloadPath?.isEmpty ?? true))
                ? const PermissionRequestScreen()
                : (initialUrl != null && initialUrl!.trim().isNotEmpty)
                ? ShareLaunchScreen(url: initialUrl!)
                : const MainNavigationContainer(),
            builder: (context, child) {
              return XdmTextScaler(
                child: AnnotatedRegion<SystemUiOverlayStyle>(
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
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _AppLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        if (TorrentService.isSupported) {
          unawaited(
            TorrentService.saveAllResumeData().catchError((e) {
              debugPrint('Failed to save torrent BG state: $e');
            }),
          );
        }
        break;
      case AppLifecycleState.resumed:
        break;
      default:
        break;
    }
  }
}

