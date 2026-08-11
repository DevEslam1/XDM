import 'package:get_it/get_it.dart';
import '../services/database_service.dart';
import '../services/download_engine.dart';
import '../services/permission_service.dart';
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

final getIt = GetIt.instance;
T inject<T extends Object>() => getIt<T>();

Future<void> configureDependencies() async {
  if (getIt.isRegistered<DatabaseService>()) return;

  getIt.registerLazySingleton<DatabaseService>(() => DatabaseService());
  getIt.registerLazySingleton<DownloadEngine>(() => DownloadEngine());
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
  
  // Fix: Ensure init() is called immediately when instantiated
  getIt.registerLazySingleton<SiteIntelligenceService>(
    () => SiteIntelligenceService()..init(),
    dispose: (service) => service.dispose(),
  );
  
  getIt.registerLazySingleton<WidgetDataBridge>(() => WidgetDataBridge.instance);
}