import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'core/app_theme.dart';
import 'core/di/injection.dart';
import 'core/services/app_lifecycle_coordinator.dart';
import 'core/services/background_service.dart';
import 'core/services/crash_reporting_service.dart';
import 'core/services/database_service.dart';
import 'core/services/diagnostic_service.dart';
import 'core/services/download_engine.dart';
import 'core/services/frame_watchdog.dart';
import 'core/services/logging_service.dart';
import 'core/services/mirror/mirror_registry.dart';
import 'core/services/notification_service.dart';
import 'core/services/performance_monitor.dart';
import 'core/services/power_monitor.dart';
import 'core/services/protocol_cache.dart';
import 'core/services/remote_api_service.dart';
import 'core/services/service_registry.dart';
import 'core/services/single_instance_service.dart';
import 'core/services/site_intelligence/site_intelligence_service.dart';
import 'core/services/torrent_resume_store.dart';
import 'core/services/torrent_service.dart';
import 'core/services/widget_deep_link.dart';
import 'core/services/xdm_backend_client.dart';
import 'core/services/youtube_service.dart';
import 'core/utils/constants.dart';
import 'core/utils/url_utils.dart';
import 'features/downloads/provider/download_filter_provider.dart';
import 'features/downloads/provider/download_list_provider.dart';
import 'features/downloads/provider/download_provider.dart';
import 'features/downloads/provider/download_queue_provider.dart';
import 'features/downloads/provider/torrent_provider.dart';
import 'features/onboarding/screens/onboarding_screen.dart';
import 'features/onboarding/screens/permission_request_screen.dart';
import 'features/settings/provider/settings_provider.dart';
import 'shared/accessibility/xdm_text_scaler.dart';
import 'shared/animation/ambient_animation_coordinator.dart';
import 'shared/animation/composite_ambient_animation_controller.dart';
import 'shared/widgets/main_navigation_container.dart';

class _ScreenObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isResumed = state == AppLifecycleState.resumed;
    if (isResumed) {
      DownloadEngine.markForeground();
    } else {
      DownloadEngine.markBackground();
    }
    PowerMonitor.setScreenOn(isResumed);
    // FIX MISC-4: Lifecycle management for watchdog, performance monitor, and pulse driver
    if (isResumed) {
      FrameWatchdog.resume();
      PerformanceMonitor.instance.resume();
      if (getIt.isRegistered<AmbientAnimationController>()) {
        getIt<AmbientAnimationController>().restartIfActive();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      FrameWatchdog.pause();
      PerformanceMonitor.instance.pause();
      if (getIt.isRegistered<AmbientAnimationController>()) {
        getIt<AmbientAnimationController>().stopAll();
      }
    }
  }

  @override
  void didHaveMemoryPressure() {
    ServiceRegistry.broadcastMemoryPressure();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    debugPrint(
        '[MemoryPressure] Cleared non-essential caches and image memory');
  }
}

Future<double> _getDeviceMemoryGB() async {
  try {
    if (kIsWeb) return 4.0;
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      if (androidInfo.isLowRamDevice) return 2.0;
      return 4.0;
    } else if (Platform.isIOS) {
      return 4.0;
    }
  } catch (e, st) {
    LoggingService.logger('main')
        .warning('Failed to detect device memory', e, st);
  }
  return 4.0;
}

final _mainLog = LoggingService.logger('main');
// FIX H-4/H-5: Store observer instances so they can be removed on app shutdown
_ScreenObserver? _screenObserver;
_AppLifecycleObserver? _appLifecycleObserver;

Future<void> main(List<String> args) async {
  CrashReportingService.runWithErrorCapture(() async {
    // ── Logging: must be first so all subsequent init can log ──
    LoggingService.init();
    CrashReportingService.captureFlutterErrors();

    // NOTE: CrashReportingService.init() must NOT be called here — WidgetsFlutterBinding
    // is not yet initialized. The authoritative init happens in PHASE 3 (after ensureInitialized).

    WidgetsFlutterBinding.ensureInitialized();

    // FIX-0.4: Adaptive ImageCache sizing based on device RAM
    final deviceMemory = await _getDeviceMemoryGB();
    final cacheMB = deviceMemory <= 2 ? 30 : 50;
    PaintingBinding.instance.imageCache
      ..maximumSizeBytes = cacheMB * 1024 * 1024
      ..maximumSize = deviceMemory <= 2 ? 60 : 100;

    // ── Frame performance monitoring (UI-jank diagnostics) ──
    if (kDebugMode) {
      await FrameWatchdog.detectRefreshRate();
      PerformanceMonitor.instance.start();
      FrameWatchdog.start();
      int consecutiveJankWindows = 0;
      FrameWatchdog.onJankDetected = (jankRatio) {
        try {
          if (!SettingsProvider.instance.jankAutoBatterySaver) {
            consecutiveJankWindows = 0;
            return;
          }
          if (jankRatio > 0.08) {
            consecutiveJankWindows++;
            if (consecutiveJankWindows >= 3) {
              SettingsProvider.instance.setBatterySaverMode(true);
            }
          } else {
            consecutiveJankWindows = 0;
          }
        } catch (e, st) {
          LoggingService.logger('main')
              .warning('Failed to check jankAutoBatterySaver', e, st);
        }
      };
    }

    await PowerMonitor.init();
    await ProtocolCache.init();

    // FIX H-4: Store observer instance so it can be removed in _AppLifecycleObserver.detached
    _screenObserver = _ScreenObserver();
    WidgetsBinding.instance.addObserver(_screenObserver!);

    // Custom error widget builder for better UX & transient error retry
    ErrorWidget.builder = (FlutterErrorDetails errorDetails) {
      return _AppErrorBoundaryWidget(errorDetails: errorDetails);
    };

    String? lastErrorHash;
    DateTime? lastErrorTime;

    PlatformDispatcher.instance.onError = (error, stack) {
      final errorKey =
          '${error.toString()}_${stack.toString().split('\n').first}';
      final now = DateTime.now();
      if (lastErrorHash == errorKey &&
          lastErrorTime != null &&
          now.difference(lastErrorTime!) < const Duration(seconds: 2)) {
        return true;
      }
      lastErrorHash = errorKey;
      lastErrorTime = now;

      debugPrint('Platform error: $error\n$stack');
      unawaited(
        CrashReportingService.recordError(
          error,
          stack,
          hint: 'PlatformDispatcher',
        ).catchError((e, st) {
          Logger('main').warning('[main] operation failed', e, st);
        }),
      );
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

      // ── Crash reporting: initializes Sentry when SENTRY_DSN is set ──
      // No-op otherwise; errors before this point go to the console logger.
      await CrashReportingService.init();
      await configureDependencies();
      // 2.2: Register the AppLifecycleCoordinator as the sole WidgetsBinding observer.
      AppLifecycleCoordinator.init();
      // FIX-E: TorrentProvider listens to engine torrentUpdates directly so the
      // coordinator path always has live metrics + taskId→torrentId mapping.
      getIt<TorrentProvider>().startListening();
      if (getIt.isRegistered<AmbientAnimationController>()) {
        getIt.unregister<AmbientAnimationController>();
      }
      getIt.registerSingleton<AmbientAnimationController>(
        (PowerMonitor.isLowEndDevice ||
                PowerMonitor.batterySaverMode != BatterySaverMode.off)
            ? const NoOpAmbientAnimationController()
            : const CompositeAmbientAnimationController(),
      );

      // ── PHASE 4: Build providers (no blocking I/O) and show UI immediately ──
      final databaseService = DatabaseService();
      final notificationService = NotificationService();
      final downloadEngine = getIt<DownloadEngine>();
      final downloadProvider = DownloadProvider(
        databaseService: databaseService,
        settingsProvider: settingsProvider,
        notificationService: notificationService,
        downloadEngine: downloadEngine,
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
        } on TimeoutException {
          // Fast timeout when no share intent is waiting - normal startup path.
        } catch (e, st) {
          Logger('main').fine('[main] share intent query error: $e', e, st);
        }
      }

      if (kDebugMode) {
        runApp(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              children: [
                DmxApp(
                  databaseService: databaseService,
                  settingsProvider: settingsProvider,
                  downloadProvider: downloadProvider,
                  initialUrl: initialUrl,
                ),
                const _FpsOverlay(),
              ],
            ),
          ),
        );
      } else {
        runApp(
          DmxApp(
            databaseService: databaseService,
            settingsProvider: settingsProvider,
            downloadProvider: downloadProvider,
            initialUrl: initialUrl,
          ),
        );
      }
      // FIX H-5: Store observer instance for proper cleanup on app detach
      _appLifecycleObserver = _AppLifecycleObserver();
      WidgetsBinding.instance.addObserver(_appLifecycleObserver!);

      // Widget deep links (dmx://) — must be registered after runApp so the
      // navigator key is attached to the MaterialApp.
      WidgetDeepLinkHandler.init(navigator: DmxApp.navigatorKey);

      // ── PHASE 5: Heavy init AFTER first frame ──
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          // DB + torrent native init in parallel.
          // Torrent MUST be ready before load() pumps torrent tasks.
          final initFutures = <Future<void>>[databaseService.init()];
          if (TorrentService.isSupported) {
            initFutures.add(() async {
              try {
                await TorrentService.init().timeout(
                  const Duration(seconds: 30),
                  onTimeout: () {
                    throw TimeoutException(
                        'TorrentService.init timed out after 30s');
                  },
                );
                if (TorrentService.isAvailable.value) {
                  _mainLog.info('Torrent service initialized successfully');
                } else {
                  _mainLog.warning(
                    'Torrent service initialization returned without an available native session',
                  );
                }
              } catch (e, s) {
                _mainLog.severe(
                  'Torrent init failed, continuing without torrent support',
                  e,
                  s,
                );
                // B2: isAvailable is now false — will be checked after load()
                //     to mark stuck torrent tasks with a visible error state.
              }
            }());
          }
          await Future.wait(initFutures);

          // Load tasks (triggers pumpQueue) — UI is already up; list populates now.
          await downloadProvider.load();

          // B2: If the torrent engine failed to initialize permanently, surface
          //     the failure to any isTorrent tasks that would otherwise hang
          //     indefinitely waiting for metadata from a non-existent session.
          if (TorrentService.isSupported && !TorrentService.isAvailable.value) {
            downloadProvider.markTorrentTasksFailed(
              'Torrent engine unavailable — tap to retry',
            );
          }
        } catch (e, s) {
          _mainLog.warning('Deferred init failed', e, s);
        }

        // Non-critical services — independent, fire-and-forget.
        unawaited(
          _initNonCriticalServices(
            downloadProvider,
            notificationService,
          ).catchError((e, st) {
            _mainLog.warning('[main] operation failed', e, st);
          }),
        );
      });
    } catch (e, stack) {
      _mainLog.severe('Initialization error', e, stack);
      runApp(ErrorApp(error: e.toString()));
    }
  });
}

Future<void> _initNonCriticalServices(
  DownloadProvider downloadProvider,
  NotificationService notificationService,
) async {
  try {
    await MirrorHealthStore.instance.init();
  } catch (e, st) {
    _mainLog.warning('Mirror health store init failed', e, st);
  }

  try {
    await XdmBackendClient.loadApiKey();
  } catch (e, st) {
    _mainLog.warning('API key load failed', e, st);
  }

  try {
    await notificationService.init(requestPermission: false);
  } catch (e, st) {
    _mainLog.warning('Notification init failed', e, st);
  }

  try {
    await BackgroundService.initialize();
  } catch (e, st) {
    _mainLog.warning('Background service init failed', e, st);
  }

  try {
    await YoutubeService.init();
  } catch (e, st) {
    _mainLog.warning('YouTube init failed', e, st);
  }

  try {
    await inject<SiteIntelligenceService>().init();
  } catch (e, st) {
    _mainLog.warning('SiteIntelligenceService init failed', e, st);
  }

  unawaited(
    RemoteApiService.start(
      getTasks: () async =>
          downloadProvider.tasks.map((t) => t.toMap()).toList(),
      pauseTask: (id) => downloadProvider.pauseTask(id),
      resumeTask: (id) => downloadProvider.resumeTask(id),
      deleteTask: (id) => downloadProvider.deleteTask(id),
    ).catchError((e, st) {
      _mainLog.warning('RemoteApiService.start failed', e, st);
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

  /// Global navigator key: lets widget deep links (`dmx://`) push screens
  /// from a cold start (see [WidgetDeepLinkHandler]).
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

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
        ChangeNotifierProvider<DownloadListProvider>(
            create: (_) => getIt<DownloadListProvider>()),
        ChangeNotifierProvider<DownloadQueueProvider>(
            create: (_) => getIt<DownloadQueueProvider>()),
        ChangeNotifierProvider<DownloadFilterProvider>(
            create: (_) => getIt<DownloadFilterProvider>()),
        ChangeNotifierProvider<TorrentProvider>(
            create: (_) => getIt<TorrentProvider>()),
      ],
      child: Selector<
          SettingsProvider,
          ({
            ThemeMode mode,
            bool isAmoled,
            String lang,
            bool showOnboarding,
            String? customDownloadPath,
            bool isDark,
          })>(
        selector: (_, s) => (
          mode: s.currentThemeMode,
          isAmoled: s.isAmoledMode,
          lang: s.languageCode,
          showOnboarding: s.showOnboarding,
          customDownloadPath: s.customDownloadPath,
          isDark: s.isDarkMode,
        ),
        builder: (context, themeData, child) {
          final isDark = themeData.isDark;
          final currentTheme = themeData.mode == ThemeMode.light
              ? AppTheme.lightTheme
              : (themeData.isAmoled
                  ? AppTheme.amoledTheme
                  : AppTheme.darkTheme);

          return MaterialApp(
            title: 'XDM - Download Manager X',
            debugShowCheckedModeBanner: false,
            navigatorKey: DmxApp.navigatorKey,
            theme: AppTheme.lightTheme,
            darkTheme:
                themeData.isAmoled ? AppTheme.amoledTheme : AppTheme.darkTheme,
            themeMode: themeData.mode,
            locale: Locale(themeData.lang),
            home: AnimatedTheme(
              data: currentTheme,
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOut,
              child: themeData.showOnboarding
                  ? const OnboardingScreen()
                  : (!kIsWeb &&
                          Platform.isAndroid &&
                          (themeData.customDownloadPath?.isEmpty ?? true))
                      ? const PermissionRequestScreen()
                      : MainNavigationContainer(
                          initialUrl: initialUrl,
                          isShareLaunch: initialUrl != null &&
                              initialUrl!.trim().isNotEmpty,
                        ),
            ),
            onGenerateRoute: (settings) {
              final rawName = settings.name ?? '';
              if (rawName.isEmpty || rawName == '/') return null;

              String? extractedUrl;
              if (rawName.startsWith('/?xt=') ||
                  rawName.contains('xt=urn:btih:')) {
                // Route caused by Android intent magnet URI: "/?xt=urn:btih:..." -> "magnet:?xt=urn:btih:..."
                extractedUrl = rawName.startsWith('/?')
                    ? 'magnet:?${rawName.substring(2)}'
                    : (rawName.startsWith('/')
                        ? rawName.substring(1)
                        : rawName);
              } else if (rawName.startsWith('/magnet:')) {
                extractedUrl = rawName.substring(1);
              } else if (isMagnetUrl(rawName) ||
                  isHttpUrl(rawName) ||
                  isTorrentFileUrl(rawName)) {
                extractedUrl = rawName;
              }

              if (extractedUrl != null && extractedUrl.isNotEmpty) {
                return MaterialPageRoute<void>(
                  settings: settings,
                  builder: (ctx) => MainNavigationContainer(
                    initialUrl: extractedUrl,
                    isShareLaunch: true,
                  ),
                );
              }
              return null;
            },
            onUnknownRoute: (settings) {
              return MaterialPageRoute<void>(
                settings: settings,
                builder: (ctx) => MainNavigationContainer(
                  initialUrl: initialUrl,
                  isShareLaunch: false,
                ),
              );
            },
            builder: (context, child) {
              return XdmTextScaler(
                child: AnnotatedRegion<SystemUiOverlayStyle>(
                  value: AppTheme.statusBar(
                    isDark,
                    isAmoled: themeData.isAmoled,
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
  static const _iosTorrentChannel = MethodChannel(
    'com.dmx.app/torrent_background',
  );
  static bool _transitionInProgress = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        NotificationService()
            .processPendingBackgroundActions()
            .catchError((e, st) {
          _mainLog.warning('processPendingBackgroundActions failed', e, st);
        }),
      );
    }

    if (state == AppLifecycleState.detached) {
      // FIX H-4/H-5: Remove stored observers to prevent leaks on re-initialization
      if (_screenObserver != null) {
        WidgetsBinding.instance.removeObserver(_screenObserver!);
        _screenObserver = null;
      }
      if (_appLifecycleObserver != null) {
        WidgetsBinding.instance.removeObserver(_appLifecycleObserver!);
        _appLifecycleObserver = null;
      }
      // App is being terminated — release wake lock and shutdown singleton services
      unawaited(shutdownDependencies().catchError((e, st) {
        _mainLog.warning('Failed to shutdown dependencies on detach', e, st);
      }));
      unawaited(BackgroundService.releaseWakeLock().catchError((e, st) {
        _mainLog.warning('Failed to release wake lock on detach', e, st);
      }));
    }

    if (!TorrentService.isSupported) return;

    switch (state) {
      case AppLifecycleState.paused:
        unawaited(
          _saveTorrentState().catchError((e, st) {
            _mainLog.warning('_saveTorrentState failed', e, st);
          }),
        );
        break;
      case AppLifecycleState.resumed:
        unawaited(
          _resumeTorrents().catchError((e, st) {
            _mainLog.warning('_resumeTorrents failed', e, st);
          }),
        );
        break;
      default:
        break;
    }
  }

  Future<void> _saveTorrentState() async {
    if (_transitionInProgress) return;
    _transitionInProgress = true;
    try {
      final ids = TorrentService.activeTorrentIds.toList();
      if (Platform.isIOS) {
        await _iosTorrentChannel.invokeMethod<void>('setActiveTorrentIds', {
          'ids': ids,
        });
      }
      await TorrentService.saveAllResumeData();
      await TorrentResumeStore.saveAll(
        TorrentService.activeTorrentIds,
        TorrentService.resumeBlobFor,
        (tid) {
          // FIX-T1: Persist per-file progress
          try {
            final files = TorrentService.getFiles(tid);
            return files
                .map((f) => {
                      'name': f.name,
                      'length': f.size,
                      'downloadedBytes': f.downloadedBytes,
                      'selected': f.selected,
                      'priority': f.priority,
                    })
                .toList();
          } catch (_) {
            return null;
          }
        },
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _mainLog.warning(
              '[TorrentResumeStore] background saveAll timed out after 5s');
        },
      );
    } catch (e, st) {
      _mainLog.warning('Failed to save torrent background state', e, st);
    } finally {
      _transitionInProgress = false;
    }
  }

  Future<void> _resumeTorrents() async {
    if (_transitionInProgress) return;
    _transitionInProgress = true;
    try {
      for (final id in TorrentService.activeTorrentIds.toList()) {
        TorrentService.resumeTorrent(id);
      }
    } catch (e, st) {
      _mainLog.warning('Failed to resume torrents after foregrounding', e, st);
    } finally {
      _transitionInProgress = false;
    }
  }
}

class _AppErrorBoundaryWidget extends StatefulWidget {
  final FlutterErrorDetails errorDetails;
  const _AppErrorBoundaryWidget({required this.errorDetails});

  @override
  State<_AppErrorBoundaryWidget> createState() =>
      _AppErrorBoundaryWidgetState();
}

class _AppErrorBoundaryWidgetState extends State<_AppErrorBoundaryWidget> {
  static int _consecutiveFailures = 0;
  static DateTime? _lastFailureTime;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    if (_lastFailureTime == null ||
        now.difference(_lastFailureTime!) > const Duration(minutes: 2)) {
      _consecutiveFailures = 0;
    }
    _lastFailureTime = now;
    _consecutiveFailures++;
    DiagnosticService.instance.record(
      'ui_build_error',
      widget.errorDetails.exceptionAsString(),
      error: widget.errorDetails.exception,
      details:
          'library=${widget.errorDetails.library} context=${widget.errorDetails.context} failures=$_consecutiveFailures',
    );
  }

  void _retry() {
    _consecutiveFailures = 0;
    _lastFailureTime = null;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final canRetry = _consecutiveFailures < 3;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: const Color(0xFF0F1117),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 440),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFF161A22),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0xFFEF4444).withValues(alpha: 0.3),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                      blurRadius: 24,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFFEF4444).withValues(alpha: 0.1),
                        border: Border.all(
                          color: const Color(0xFFEF4444).withValues(alpha: 0.3),
                        ),
                      ),
                      child: const Icon(
                        Icons.warning_amber_rounded,
                        size: 36,
                        color: Color(0xFFEF4444),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'SIGNAL DIAGNOSTIC ERROR',
                      style: TextStyle(
                        fontFamily: 'Space Grotesk',
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                        color: Color(0xFFF2F4F8),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      kDebugMode
                          ? widget.errorDetails.exceptionAsString()
                          : 'An unexpected application exception occurred.',
                      textAlign: TextAlign.center,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        color: Color(0xFF9AA3B5),
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(
                                  text: widget.errorDetails.toString(),
                                ),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content:
                                      Text('Diagnostics copied to clipboard'),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy_rounded, size: 14),
                            label: const Text('COPY DIAGNOSTICS'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF9AA3B5),
                              side: const BorderSide(color: Color(0xFF2A3040)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              textStyle: const TextStyle(
                                fontFamily: 'Space Grotesk',
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: canRetry ? _retry : () => exit(0),
                            icon: Icon(
                              canRetry
                                  ? Icons.refresh_rounded
                                  : Icons.power_settings_new_rounded,
                              size: 14,
                            ),
                            label: Text(canRetry ? 'RETRY' : 'RELOAD APP'),
                            style: FilledButton.styleFrom(
                              backgroundColor: canRetry
                                  ? const Color(0xFF3B82F6)
                                  : const Color(0xFFEF4444),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              textStyle: const TextStyle(
                                fontFamily: 'Space Grotesk',
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FpsOverlay extends StatefulWidget {
  const _FpsOverlay();

  @override
  _FpsOverlayState createState() => _FpsOverlayState();
}

class _FpsOverlayState extends State<_FpsOverlay> {
  int _frameCount = 0;
  double _fps = 0;
  Timer? _timer;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    _active = true;
    _scheduleNextFrame();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (PowerMonitor.screenOff || DownloadEngine.isInBackground) return;
      if (mounted) {
        setState(() {
          _fps = _frameCount.toDouble();
          _frameCount = 0;
        });
      }
    });
  }

  void _scheduleNextFrame() {
    if (!_active ||
        !mounted ||
        PowerMonitor.screenOff ||
        DownloadEngine.isInBackground) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_active ||
          !mounted ||
          PowerMonitor.screenOff ||
          DownloadEngine.isInBackground) {
        return;
      }
      _frameCount++;
      _scheduleNextFrame();
    });
  }

  @override
  void dispose() {
    _active = false;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 40,
      right: 8,
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            '${_fps.round()} fps',
            style: const TextStyle(
              color: Colors.greenAccent,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}
