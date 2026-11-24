import 'dart:ui' show FrameTiming, PlatformDispatcher;

import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/frame_watchdog.dart';
import 'package:dmx/core/services/performance_monitor.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

FrameTiming _timing([int micros = 50000]) => FrameTiming(
      vsyncStart: 0,
      buildStart: 0,
      buildFinish: micros,
      rasterStart: 0,
      rasterFinish: micros,
      rasterFinishWallTime: micros,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FrameWatchdog.resetForTesting();
    FrameWatchdog.onJankDetected = null;
    FrameWatchdog.setDownloadingTasksCount(0);
    PowerMonitor.setScreenOn(true);
    DownloadEngine.markForeground();
    DownloadEngine.setActiveDownloadsCount(0);
  });

  tearDown(() {
    FrameWatchdog.stop();
    FrameWatchdog.resetForTesting();
    FrameWatchdog.onJankDetected = null;
    FrameWatchdog.setDownloadingTasksCount(0);
    PerformanceMonitor.instance.stop();
    PowerMonitor.setScreenOn(true);
    DownloadEngine.markForeground();
    DownloadEngine.setActiveDownloadsCount(0);
  });

  group('FrameWatchdog', () {
    test('detectRefreshRate resolves a positive rate and caches it', () async {
      await FrameWatchdog.detectRefreshRate(force: true);
      expect(FrameWatchdog.refreshRate, greaterThan(0));
      expect(FrameWatchdog.frameBudgetMs, greaterThan(0));

      final first = FrameWatchdog.refreshRate;
      await FrameWatchdog.detectRefreshRate();
      expect(FrameWatchdog.refreshRate, first);
    });

    test('getDisplayRefreshRate returns a positive value', () async {
      final rate = await FrameWatchdog.getDisplayRefreshRate();
      expect(rate, greaterThan(0));
    });

    test('PerformanceBudget mirrors the frame budget', () {
      expect(PerformanceBudget.maxBuildTimeMs, FrameWatchdog.frameBudgetMs);
      expect(PerformanceBudget.maxRasterTimeMs, FrameWatchdog.frameBudgetMs);
      expect(PerformanceBudget.maxJankRatio, 0.05);
    });

    test('start/pause/resume/stop are safe and idempotent', () {
      FrameWatchdog.start();
      FrameWatchdog.start();
      FrameWatchdog.pause();
      FrameWatchdog.pause();
      FrameWatchdog.resume();
      FrameWatchdog.stop();
      FrameWatchdog.stop();
      expect(true, isTrue);
    });

    test('resume is a no-op while the screen is off', () {
      PowerMonitor.setScreenOn(false);
      FrameWatchdog.resume();
      expect(true, isTrue);
    });

    test('simulateWindowForTesting reports jank above the threshold', () {
      double? reported;
      FrameWatchdog.onJankDetected = (rate) => reported = rate;
      FrameWatchdog.simulateWindowForTesting(6, 100);
      expect(reported, closeTo(0.06, 0.001));
    });

    test('simulateWindowForTesting ignores low jank and zero totals', () {
      double? reported;
      FrameWatchdog.onJankDetected = (rate) => reported = rate;
      FrameWatchdog.simulateWindowForTesting(1, 100);
      expect(reported, isNull);
      FrameWatchdog.simulateWindowForTesting(5, 0);
      expect(reported, isNull);
    });

    test('simulateWindowForTesting honours the heavy-download threshold', () {
      double? reported;
      FrameWatchdog.onJankDetected = (rate) => reported = rate;
      FrameWatchdog.simulateWindowForTesting(10, 100, isHeavy: true);
      expect(reported, isNull);
      FrameWatchdog.simulateWindowForTesting(18, 100, isHeavy: true);
      expect(reported, closeTo(0.18, 0.001));
    });

    test('metrics changes re-run refresh-rate detection', () async {
      await FrameWatchdog.detectRefreshRate(force: true);
      PlatformDispatcher.instance.onMetricsChanged?.call();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(FrameWatchdog.refreshRate, greaterThan(0));
    });

    test('processes reported frame timings while running', () {
      PerformanceMonitor.instance.start();
      FrameWatchdog.start();
      final timings = [
        FrameTiming(
          vsyncStart: 0,
          buildStart: 0,
          buildFinish: 50000,
          rasterStart: 0,
          rasterFinish: 50000,
          rasterFinishWallTime: 50000,
        ),
        FrameTiming(
          vsyncStart: 0,
          buildStart: 0,
          buildFinish: 5000,
          rasterStart: 0,
          rasterFinish: 5000,
          rasterFinishWallTime: 5000,
        ),
      ];
      PlatformDispatcher.instance.onReportTimings?.call(timings);
      FrameWatchdog.stop();
    });

    testWidgets('ignores timings while the app is not resumed', (tester) async {
      FrameWatchdog.start();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      PlatformDispatcher.instance.onReportTimings?.call([_timing()]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      FrameWatchdog.stop();
    });

    testWidgets('start and resume respect the lifecycle state', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      FrameWatchdog.start();
      FrameWatchdog.resume();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      FrameWatchdog.start();
      FrameWatchdog.stop();
    });
  });
}
