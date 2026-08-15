import 'package:get_it/get_it.dart';
import '../services/database_service.dart';
import '../services/mirror_health_store.dart';
import '../services/app_lifecycle_coordinator.dart';
import '../services/background_timer_manager.dart';
import '../../features/downloads/widgets/download_card.dart';
import '../../shared/widgets/geometric_grid_background.dart';
import '../../features/downloads/data/task_repository.dart';
import '../../features/downloads/data/drift_task_repository.dart';
import '../../features/downloads/provider/download_list_provider.dart';
import '../../features/downloads/provider/download_queue_provider.dart';
import '../../features/downloads/provider/download_filter_provider.dart';
import '../../features/downloads/provider/torrent_provider.dart';
import '../../features/downloads/provider/download_coordinator.dart';
import '../../features/downloads/usecases/start_download_usecase.dart';
import '../../features/downloads/usecases/pause_download_usecase.dart';
import '../../features/downloads/usecases/resume_download_usecase.dart';
import '../../features/downloads/usecases/cancel_download_usecase.dart';
import '../../features/downloads/usecases/retry_download_usecase.dart';
import '../../features/downloads/usecases/delete_download_usecase.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../services/download_engine.dart';
import '../services/engines/connection_warmer.dart';
import '../services/network/cookie_cache.dart';
import '../services/permission_service.dart';
import '../services/power_monitor.dart';
import '../services/connection_manager.dart';
import '../services/bandwidth_governor.dart';
import '../services/checksum_service.dart';
import '../services/notification_service.dart';
import '../services/clipboard_service.dart';
import '../services/share_url_handler.dart';
import '../services/background_service.dart';
import '../services/crash_reporting_service.dart';
import '../services/app_lock_service.dart';
import '../services/xdm_backend_client.dart';
import '../services/update_service.dart';
import '../services/single_instance_service.dart';
import '../services/tracker_manager.dart';
import '../services/widget_data_bridge.dart';
import '../services/site_intelligence/site_intelligence_service.dart';
import '../services/shared_prefs_batcher.dart';
import '../services/torrent_service.dart';

final getIt = GetIt.instance;
T inject<T extends Object>() => getIt<T>();

Future<void> configureDependencies() async {
  if (getIt.isRegistered<DatabaseService>()) return;

  getIt.registerLazySingleton<DatabaseService>(() => DatabaseService());
  getIt.registerLazySingleton<TaskRepository>(
    () => DriftTaskRepository(getIt<DatabaseService>()),
  );
  getIt.registerLazySingleton<DownloadListProvider>(
    () => DownloadListProvider(getIt<TaskRepository>()),
  );
  getIt.registerLazySingleton<DownloadQueueProvider>(
    () => DownloadQueueProvider(
      listProvider: getIt<DownloadListProvider>(),
      settings: getIt<SettingsProvider>(),
    ),
  );
  getIt.registerLazySingleton<DownloadFilterProvider>(
    () => DownloadFilterProvider(getIt<DownloadListProvider>()),
  );
  getIt.registerLazySingleton<TorrentProvider>(
    () => TorrentProvider(),
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
  );

  // Clean Architecture Use Cases
  getIt.registerLazySingleton<StartDownloadUseCase>(
    () => StartDownloadUseCase(
      getIt<DownloadListProvider>(),
      getIt<DownloadQueueProvider>(),
    ),
  );
  getIt.registerLazySingleton<PauseDownloadUseCase>(
    () => PauseDownloadUseCase(getIt<DownloadQueueProvider>()),
  );
  getIt.registerLazySingleton<ResumeDownloadUseCase>(
    () => ResumeDownloadUseCase(getIt<DownloadQueueProvider>()),
  );
  getIt.registerLazySingleton<CancelDownloadUseCase>(
    () => CancelDownloadUseCase(getIt<DownloadListProvider>()),
  );
  getIt.registerLazySingleton<RetryDownloadUseCase>(
    () => RetryDownloadUseCase(
      getIt<DownloadListProvider>(),
      getIt<DownloadQueueProvider>(),
    ),
  );
  getIt.registerLazySingleton<DeleteDownloadUseCase>(
    () => DeleteDownloadUseCase(getIt<DownloadListProvider>()),
  );

  // Download Engine & Decoupled Services
  getIt.registerLazySingleton<DioClientPool>(() => DioClientPool());
  getIt.registerLazySingleton<YtCounterpartCoordinator>(() => YtCounterpartCoordinator());
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
  getIt.registerLazySingleton<TorrentDownloadOrchestrator>(
    () => TorrentDownloadOrchestrator(getIt<DioClientPool>()),
  );

  getIt.registerLazySingleton<DownloadEngine>(
    () => DownloadEngine(
      httpOrchestrator: getIt<HttpDownloadOrchestrator>(),
      torrentOrchestrator: getIt<TorrentDownloadOrchestrator>(),
      metadataService: getIt<MetadataProbeService>(),
      ytCoordinator: getIt<YtCounterpartCoordinator>(),
      dioPool: getIt<DioClientPool>(),
    ),
  );
  getIt.registerLazySingleton<PowerMonitor>(() => PowerMonitor());
  getIt.registerLazySingleton<PermissionService>(() => PermissionService());
  getIt.registerLazySingleton<ConnectionManager>(() => ConnectionManager());
  getIt.registerLazySingleton<BandwidthGovernor>(() => BandwidthGovernor(0),
      dispose: (governor) => governor.dispose());
  getIt.registerLazySingleton<ChecksumService>(() => ChecksumService());
  getIt.registerLazySingleton<NotificationService>(() => NotificationService());
  getIt.registerLazySingleton<ClipboardService>(() => ClipboardService());
  getIt.registerLazySingleton<ShareUrlHandler>(() => ShareUrlHandler());
  getIt.registerLazySingleton<BackgroundService>(() => BackgroundService());
  getIt.registerLazySingleton<CrashReportingService>(
      () => CrashReportingService());
  getIt.registerLazySingleton<AppLockService>(() => AppLockService());
  getIt.registerLazySingleton<XdmBackendClient>(() => XdmBackendClient());
  getIt.registerLazySingleton<UpdateService>(() => UpdateService());
  getIt.registerLazySingleton<SingleInstanceService>(
      () => SingleInstanceService());
  getIt.registerLazySingleton<TrackerManager>(() => TrackerManager());

  getIt.registerLazySingleton<SiteIntelligenceService>(
    () => SiteIntelligenceService()..init(),
    dispose: (service) => service.dispose(),
  );

  getIt.registerLazySingleton<ConnectionWarmer>(() => ConnectionWarmer(),
      dispose: (warmer) => warmer.dispose());
  getIt.registerLazySingleton<CookieCache>(() => CookieCache(),
      dispose: (cache) => cache.dispose());

  getIt.registerLazySingleton<MirrorHealthStore>(
    () => MirrorHealthStore(),
    dispose: (s) => s.dispose(),
  );

  getIt.registerLazySingleton<AppLifecycleCoordinator>(
    () => AppLifecycleCoordinator(),
    dispose: (s) => AppLifecycleCoordinator.dispose(),
  );

  getIt.registerLazySingleton<TorrentSeedingManager>(
    () => TorrentSeedingManager(),
  );

  getIt.registerLazySingleton<StatusChipPulseDriver>(
    () => StatusChipPulseDriver(),
    dispose: (s) => s.dispose(),
  );

  getIt.registerLazySingleton<AmbientProgress>(
    () => AmbientProgress(),
  );

  getIt.registerLazySingleton<BackgroundTimerManager>(
    () => BackgroundTimerManager.instance,
  );

  getIt.registerLazySingleton<WidgetDataBridge>(() => WidgetDataBridge.instance);

  getIt.registerLazySingleton<SharedPrefsBatcher>(
    () => SharedPrefsBatcher.instance,
    dispose: (b) => b.dispose(),
  );

  getIt.registerLazySingleton<TorrentService>(
    () => TorrentService(),
    dispose: (_) => TorrentService.dispose(),
  );
}
