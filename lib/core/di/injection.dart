import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import '../../features/downloads/data/drift_task_repository.dart';
import '../../features/downloads/data/task_repository.dart';
import '../../features/downloads/provider/download_coordinator.dart';
import '../../features/downloads/provider/download_filter_provider.dart';
import '../../features/downloads/provider/download_list_provider.dart';
import '../../features/downloads/provider/download_queue_provider.dart';
import '../../features/downloads/provider/torrent_provider.dart';
import '../../features/downloads/services/torrent_session_manager.dart';
import '../../features/downloads/usecases/cancel_download_usecase.dart';
import '../../features/downloads/usecases/delete_download_usecase.dart';
import '../../features/downloads/usecases/pause_download_usecase.dart';
import '../../features/downloads/usecases/resume_download_usecase.dart';
import '../../features/downloads/usecases/retry_download_usecase.dart';
import '../../features/downloads/usecases/start_download_usecase.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../../shared/animation/ambient_animation_coordinator.dart';
import '../../shared/animation/composite_ambient_animation_controller.dart';
import '../interfaces/i_torrent_service.dart';
import '../services/app_lifecycle_coordinator.dart';
import '../services/app_lock_service.dart';
import '../services/background_service.dart';
import '../services/background_timer_manager.dart';
import '../services/bandwidth_governor.dart';
import '../services/checksum_service.dart';
import '../services/clipboard_service.dart';
import '../services/connection_manager.dart';
import '../services/crash_reporting_service.dart';
import '../services/database/repositories/bookmark_repository.dart';
import '../services/database/repositories/browser_history_repository.dart';
import '../services/database/repositories/browser_tab_repository.dart';
import '../services/database/services/database_maintenance_service.dart';
import '../services/database_service.dart';
import '../services/dio_client_pool.dart';
import '../services/download_engine.dart';
import '../services/download_journal.dart';
import '../services/engine/server_identity_cache.dart';
import '../services/engine/torrent_download_handler.dart';
import '../services/engines/connection_warmer.dart';
import '../services/http_download_orchestrator.dart';
import '../services/metadata_probe_service.dart';
import '../services/mirror/mirror_registry.dart';
import '../services/network/cookie_cache.dart';
import '../services/notification_service.dart';
import '../services/permission_service.dart';
import '../services/power_monitor.dart';
import '../services/service_registry.dart';
import '../services/share_url_handler.dart';
import '../services/shared_prefs_batcher.dart';
import '../services/single_instance_service.dart';
import '../services/site_intelligence/site_intelligence_service.dart';
import '../services/torrent_download_orchestrator.dart';
import '../services/torrent_service.dart';
import '../services/tracker_manager.dart';
import '../services/update_service.dart';
import '../services/widget_data_bridge.dart';
import '../services/xdm_backend_client.dart';
import '../services/yt_counterpart_coordinator.dart';

final getIt = GetIt.instance;
T inject<T extends Object>() => getIt<T>();

Future<void> configureDependencies() async {
  if (getIt.isRegistered<DatabaseService>()) return;

  getIt.registerLazySingleton<StateStoreFactory>(() => StateStoreFactory());
  getIt.registerLazySingleton<StateStoreInstance>(
      () => getIt<StateStoreFactory>().defaultStore);
  getIt
      .registerLazySingleton<SettingsProvider>(() => SettingsProvider.instance);
  getIt.registerLazySingleton<DatabaseService>(() => DatabaseService());
  getIt.registerLazySingleton<BookmarkRepository>(
    () => getIt<DatabaseService>().bookmarks,
  );
  getIt.registerLazySingleton<BrowserHistoryRepository>(
    () => getIt<DatabaseService>().history,
  );
  getIt.registerLazySingleton<BrowserTabRepository>(
    () => getIt<DatabaseService>().tabs,
  );
  getIt.registerLazySingleton<DatabaseMaintenanceService>(
    () => getIt<DatabaseService>().maintenance,
  );
  getIt.registerLazySingleton<TaskRepository>(
    () => DriftTaskRepository(getIt<DatabaseService>()),
  );
  getIt.registerLazySingleton<DownloadListProvider>(
    () => DownloadListProvider(getIt<TaskRepository>()),
    dispose: (p) => p.dispose(),
  );
  getIt.registerLazySingleton<DownloadQueueProvider>(
    () => DownloadQueueProvider(
      listProvider: getIt<DownloadListProvider>(),
      settings: getIt<SettingsProvider>(),
    ),
    dispose: (p) => p.dispose(),
  );
  getIt.registerLazySingleton<DownloadFilterProvider>(
    () => DownloadFilterProvider(getIt<DownloadListProvider>()),
    dispose: (p) => p.dispose(),
  );
  getIt.registerLazySingleton<TorrentProvider>(
    () => TorrentProvider(),
    dispose: (p) => p.dispose(),
  );
  getIt.registerLazySingleton<DownloadCoordinator>(
    () => DownloadCoordinator(
      listProvider: getIt<DownloadListProvider>(),
      queueProvider: getIt<DownloadQueueProvider>(),
      filterProvider: getIt<DownloadFilterProvider>(),
      torrentProvider: getIt<TorrentProvider>(),
      pauseUseCase: getIt<PauseDownloadUseCase>(),
      resumeUseCase: getIt<ResumeDownloadUseCase>(),
      deleteUseCase: getIt<DeleteDownloadUseCase>(),
    ),
    dispose: (c) => c.dispose(),
  );

  getIt.registerLazySingleton<DownloadProvider>(
    () => DownloadProvider(
      databaseService: getIt<DatabaseService>(),
      settingsProvider: getIt<SettingsProvider>(),
      downloadEngine: getIt<DownloadEngine>(),
      permissionService: getIt<PermissionService>(),
      notificationService: getIt<NotificationService>(),
    ),
    dispose: (p) => p.dispose(),
  );

  // Clean Architecture Use Cases (deprecated stubs — forward to DownloadProvider)
  getIt.registerLazySingleton<StartDownloadUseCase>(
    // ignore: deprecated_member_use_from_same_package
    () => StartDownloadUseCase(getIt<DownloadProvider>()),
  );
  getIt.registerLazySingleton<PauseDownloadUseCase>(
    () => PauseDownloadUseCase(
      getIt<DownloadQueueProvider>(),
      getIt<TorrentProvider>(),
    ),
  );
  getIt.registerLazySingleton<ResumeDownloadUseCase>(
    () => ResumeDownloadUseCase(getIt<DownloadQueueProvider>()),
  );
  getIt.registerLazySingleton<CancelDownloadUseCase>(
    // ignore: deprecated_member_use_from_same_package
    () => CancelDownloadUseCase(getIt<DownloadProvider>()),
  );
  getIt.registerLazySingleton<RetryDownloadUseCase>(
    // ignore: deprecated_member_use_from_same_package
    () => RetryDownloadUseCase(getIt<DownloadProvider>()),
  );
  getIt.registerLazySingleton<DeleteDownloadUseCase>(
    () => DeleteDownloadUseCase(
      getIt<DownloadListProvider>(),
      getIt<TorrentProvider>(),
    ),
  );

  // Download Engine & Decoupled Services
  getIt.registerLazySingleton<DioClientPool>(
    () => DioClientPool(),
    dispose: (p) => p.dispose(),
  );
  getIt.registerLazySingleton<YtCounterpartCoordinator>(
      () => YtCounterpartCoordinator());
  getIt.registerLazySingleton<MetadataProbeService>(
    () => MetadataProbeService(getIt<DioClientPool>()),
  );
  getIt.registerLazySingleton<HttpDownloadOrchestrator>(
    () => HttpDownloadOrchestrator(
      getIt<MetadataProbeService>(),
      getIt<YtCounterpartCoordinator>(),
      getIt<SettingsProvider>(),
    ),
  );
  getIt.registerLazySingleton<ITorrentService>(
    () => TorrentServiceImpl(),
    dispose: (s) => s.dispose(),
  );
  getIt.registerLazySingleton<TorrentDownloadHandler>(
    () => TorrentDownloadHandler(),
    dispose: (h) => h.dispose(),
  );
  getIt.registerLazySingleton<TorrentDownloadOrchestrator>(
    () => TorrentDownloadOrchestrator(
      getIt<DioClientPool>(),
      getIt<TorrentDownloadHandler>(),
    ),
  );

  getIt.registerLazySingleton<DownloadEngine>(
    () => DownloadEngine(
      httpOrchestrator: getIt<HttpDownloadOrchestrator>(),
      torrentOrchestrator: getIt<TorrentDownloadOrchestrator>(),
      torrentHandler: getIt<TorrentDownloadHandler>(),
      metadataService: getIt<MetadataProbeService>(),
      ytCoordinator: getIt<YtCounterpartCoordinator>(),
      dioPool: getIt<DioClientPool>(),
    ),
    dispose: (e) => e.dispose(),
  );
  getIt.registerLazySingleton<PowerMonitor>(
    () => PowerMonitor(),
    dispose: (_) => PowerMonitor.dispose(),
  );
  getIt.registerLazySingleton<PermissionService>(() => PermissionService());
  getIt.registerLazySingleton<ConnectionManager>(() => ConnectionManager(),
      dispose: (c) => c.dispose());
  getIt.registerLazySingleton<ServerIdentityCache>(
      () => ServerIdentityCache(),
      dispose: (c) => c.dispose());
  getIt.registerLazySingleton<BandwidthGovernor>(
      () => BandwidthGovernor(BandwidthGovernor.unlimited),
      dispose: (governor) => governor.dispose());
  getIt.registerLazySingleton<ChecksumService>(() => ChecksumService());
  getIt.registerLazySingleton<NotificationService>(
    () => NotificationService(),
    dispose: (n) => n.dispose(),
  );
  getIt.registerLazySingleton<ClipboardService>(() => ClipboardService());
  getIt.registerLazySingleton<ShareUrlHandler>(() => ShareUrlHandler());
  getIt.registerLazySingleton<BackgroundService>(
    () => BackgroundService(),
    dispose: (b) => b.dispose(),
  );
  getIt.registerLazySingleton<CrashReportingService>(
      () => CrashReportingService());
  getIt.registerLazySingleton<AppLockService>(() => AppLockService());
  getIt.registerLazySingleton<XdmBackendClient>(() => XdmBackendClient());
  getIt.registerLazySingleton<UpdateService>(
    () => UpdateService(),
    dispose: (u) => u.dispose(),
  );
  getIt.registerLazySingleton<SingleInstanceService>(
      () => SingleInstanceService());
  getIt.registerLazySingleton<TrackerManager>(
    () => TrackerManager(),
    dispose: (t) => t.dispose(),
  );

  getIt.registerLazySingleton<SiteIntelligenceService>(
    () => SiteIntelligenceService(),
    dispose: (service) => service.dispose(),
  );

  getIt.registerLazySingleton<ServerProfileManager>(
    () => ServerProfileManager(),
    dispose: (s) => s.dispose(),
  );
  getIt.registerLazySingleton<MirrorBenchmarkService>(
    () => MirrorBenchmarkService(),
    dispose: (s) => s.dispose(),
  );

  getIt.registerLazySingleton<ConnectionWarmer>(() => ConnectionWarmer(),
      dispose: (warmer) => warmer.dispose());
  getIt.registerLazySingleton<CookieCache>(() => CookieCache(),
      dispose: (cache) => cache.dispose());

  getIt.registerLazySingleton<MirrorHealthStore>(
    () => MirrorHealthStore(),
    dispose: (s) => s.dispose(),
  );
  getIt.registerLazySingleton<MirrorRegistry>(
    () => MirrorRegistry(),
    dispose: (r) => r.dispose(),
  );

  getIt.registerLazySingleton<AppLifecycleCoordinator>(
    () => AppLifecycleCoordinator(),
    dispose: (s) => AppLifecycleCoordinator.dispose(),
  );

  getIt.registerLazySingleton<TorrentSessionManager>(
    () => TorrentSessionManager(),
    dispose: (m) => m.dispose(),
  );

  getIt.registerLazySingleton<AmbientAnimationController>(
    () => (PowerMonitor.isLowEndDevice ||
            PowerMonitor.batterySaverMode != BatterySaverMode.off)
        ? const NoOpAmbientAnimationController()
        : const CompositeAmbientAnimationController(),
  );

  getIt.registerLazySingleton<BackgroundTimerManager>(
    () => BackgroundTimerManager(),
    dispose: (m) => m.dispose(),
  );

  getIt.registerLazySingleton<WidgetDataBridge>(
    () => WidgetDataBridge(),
    dispose: (w) => w.dispose(),
  );

  getIt.registerLazySingleton<SharedPrefsBatcher>(
    () => SharedPrefsBatcher(),
    dispose: (b) => b.dispose(),
  );
}

/// Shuts down and disposes all registered singleton dependencies on app detach.
Future<void> shutdownDependencies() async {
  await ServiceRegistry.shutdownAll();
  await getIt.reset();
}

/// Helper for resetting GetIt dependency graph between tests.
@visibleForTesting
Future<void> resetDependenciesForTesting() async {
  await getIt.reset();
}
