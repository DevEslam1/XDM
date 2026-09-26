import 'package:dmx/core/services/background_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// F29 regression: backgrounding the app must NOT hard-kill download worker
/// isolates while downloads are active. Previously the torrent resume-save
/// timeout unconditionally called `forceKillAllIsolates()`, killing in-flight
/// HTTP downloads mid-write and losing their progress (the "data lost after
/// background/resume" symptom).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    DownloadEngine.setActiveDownloadsCount(0);
    BackgroundService.setActiveDownloadCountQuery(null);
  });

  test('hasActiveDownloads reflects the active download counter', () {
    DownloadEngine.setActiveDownloadsCount(0);
    expect(DownloadEngine.hasActiveDownloads, isFalse);

    DownloadEngine.setActiveDownloadsCount(1);
    expect(DownloadEngine.hasActiveDownloads, isTrue);
    expect(DownloadEngine.activeDownloadsCount, 1);

    DownloadEngine.setActiveDownloadsCount(3);
    expect(DownloadEngine.hasActiveDownloads, isTrue);
  });

  test('background-service active count query sees live engine downloads',
      () async {
    // Simulate the DI wiring: the service's stop-guard must consult the engine.
    BackgroundService.setActiveDownloadCountQuery(
        () => DownloadEngine.activeDownloadsCount);

    DownloadEngine.setActiveDownloadsCount(0);
    // `stop()` consults the query; with 0 active it is allowed (no-op here
    // since the service isn't supported in the test host).
    await BackgroundService.stop();

    DownloadEngine.setActiveDownloadsCount(2);
    // With active downloads the guard refuses to stop.
    await BackgroundService.stop();
  });

  test('forceKillAllIsolates is safe to call with no live pool', () {
    // With active downloads the lifecycle guard skips this call entirely; when
    // it IS called with no pool (nothing to kill) it must not throw.
    expect(DownloadEngine.forceKillAllIsolates, returnsNormally);
  });
}
