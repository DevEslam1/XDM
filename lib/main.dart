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
import 'core/services/diagnostic_service.dart';
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
import 'core/services/frame_watchdog.dart';
import 'core/services/power_monitor.dart';
import 'core/services/protocol_cache.dart';
import 'core/services/widget_deep_link.dart';
import 'core/services/local_proxy_service.dart';

class _ScreenObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    PowerMonitor.setScreenOn(state == AppLifecycleState.resumed);
  }
}

Future<void> main(List<String> args) async {
  CrashReportingService.runWithErrorCapture(() async {
    // ── Logging: must be first so all subsequent init can log ──
    LoggingService.init();
    CrashReportingService.captureFlutterErrors();

    // ── Crash reporting: NoOp unless SENTRY_DSN is provided via
    //    --dart-define=SENTRY_DSN=... (see crash_reporting_service.dart) ──
    try {
      await CrashReportingService.init();
    } catch (e) {
      debugPrint('Crash reporting init failed: $e');
    }

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
      } catch (_) {
        // SettingsProvider.instance not loaded yet, ignore
      }
    };


    await PowerMonitor.init();
    await ProtocolCache.init();

    WidgetsBinding.instance.addObserver(_ScreenObserver());

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

      await LocalProxyService.instance.start();

      // ── Crash reporting: initializes Sentry when SENTRY_DSN is set ──
      // No-op otherwise; errors before this point go to the console logger.
      await CrashReportingService.init();

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
        } catch (e, st) {
          Logger('main').warning('[main] operation failed', e, st);
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
      WidgetsBinding.instance.addObserver(_AppLifecycleObserver());

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
                await TorrentResumeStore.init();
                await TorrentService.init();
                debugPrint('Torrent service initialized successfully');
              } catch (e, s) {
                debugPrint(
                  'Torrent init failed, continuing without torrent support: $e',
                );
                Logger('main').severe('Torrent init failed', e, s);
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
          debugPrint('Deferred init failed: $e\n$s');
        }

        // Non-critical services — independent, fire-and-forget.
        unawaited(
          _initNonCriticalServices(
            downloadProvider,
            notificationService,
          ).catchError((e, st) {
            Logger('main').warning('[main] operation failed', e, st);
          }),
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
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, child) {
          final isDark = settings.isDarkMode;
          return MaterialApp(
            title: 'XDM - Download Manager X',
            debugShowCheckedModeBanner: false,
            navigatorKey: DmxApp.navigatorKey,
            theme: AppTheme.lightTheme,
            darkTheme:
                settings.isAmoledMode ? AppTheme.amoledTheme : AppTheme.darkTheme,
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
                  value: AppTheme.statusBar(
                    isDark,
                    isAmoled: settings.isAmoledMode,
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
      unawaited(NotificationService().processPendingBackgroundActions());
    }

    if (state == AppLifecycleState.detached) {
      // App is being terminated — release wake lock
      unawaited(BackgroundService.releaseWakeLock().catchError((e) {
        debugPrint('Failed to release wake lock on detach: $e');
      }));
    }

    if (!TorrentService.isSupported) return;

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        unawaited(_saveTorrentState());
        break;
      case AppLifecycleState.resumed:
        unawaited(_resumeTorrents());
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
        TorrentService.progressFor,
        (tid) {
          // FIX-T1: Persist per-file progress
          try {
            final files = TorrentService.getFiles(tid);
            return files.map((f) => {
              'name': f.name,
              'length': f.size,
              'downloadedBytes': f.downloadedBytes,
              'selected': f.selected,
              'priority': f.priority,
            }).toList();
          } catch (_) {
            return null;
          }
        },
      );
    } catch (e) {
      debugPrint('Failed to save torrent background state: $e');
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
    } catch (e) {
      debugPrint('Failed to resume torrents after foregrounding: $e');
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

  @override
  void initState() {
    super.initState();
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
    if (_consecutiveFailures < 3) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final canRetry = _consecutiveFailures < 3;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: const Color(0xFF0F1117),
        body: Center(
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPersistentFrameCallback((_) {
      _frameCount++;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _fps = _frameCount.toDouble();
          _frameCount = 0;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
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

