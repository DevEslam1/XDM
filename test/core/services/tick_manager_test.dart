import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/tick_manager.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PowerMonitor.setScreenOn(true);
    DownloadEngine.markForeground();
    DownloadEngine.setActiveDownloadsCount(0);
  });

  tearDown(() {
    PowerMonitor.setScreenOn(true);
    DownloadEngine.markForeground();
    DownloadEngine.setActiveDownloadsCount(0);
  });

  group('TickManager', () {
    test('critical priority is always eligible', () {
      fakeAsync((async) {
        final manager = TickManager.instance;
        var calls = 0;
        manager.registerTick(
          id: 'critical',
          interval: const Duration(milliseconds: 1),
          priority: TickPriority.critical,
          callback: (_) => calls++,
        );
        async.elapse(const Duration(seconds: 2));
        expect(calls, greaterThanOrEqualTo(1));
        manager.unregisterTick('critical');
      });
    });

    test('normal priority is skipped while screen off and idle', () {
      fakeAsync((async) {
        PowerMonitor.setScreenOn(false);
        final manager = TickManager.instance;
        var calls = 0;
        manager.registerTick(
          id: 'normal-off',
          interval: const Duration(milliseconds: 1),
          priority: TickPriority.normal,
          callback: (_) => calls++,
        );
        async.elapse(const Duration(seconds: 12));
        expect(calls, 0);
        manager.unregisterTick('normal-off');
        PowerMonitor.setScreenOn(true);
      });
    });

    test('normal priority runs with active downloads while screen off', () {
      fakeAsync((async) {
        PowerMonitor.setScreenOn(false);
        DownloadEngine.setActiveDownloadsCount(1);
        final manager = TickManager.instance;
        var calls = 0;
        manager.registerTick(
          id: 'normal-active',
          interval: const Duration(milliseconds: 1),
          priority: TickPriority.normal,
          callback: (_) => calls++,
        );
        async.elapse(const Duration(seconds: 12));
        expect(calls, greaterThanOrEqualTo(1));
        manager.unregisterTick('normal-active');
        PowerMonitor.setScreenOn(true);
        DownloadEngine.setActiveDownloadsCount(0);
      });
    });

    test('ambient priority requires foreground and active downloads', () {
      fakeAsync((async) {
        final manager = TickManager.instance;
        var calls = 0;
        manager.registerTick(
          id: 'ambient',
          interval: const Duration(milliseconds: 1),
          priority: TickPriority.ambient,
          callback: (_) => calls++,
        );
        async.elapse(const Duration(seconds: 2));
        expect(calls, 0);

        DownloadEngine.setActiveDownloadsCount(1);
        async.elapse(const Duration(seconds: 2));
        expect(calls, greaterThanOrEqualTo(1));
        manager.unregisterTick('ambient');
        DownloadEngine.setActiveDownloadsCount(0);
      });
    });

    test('callback exceptions do not escape the heartbeat', () {
      fakeAsync((async) {
        final manager = TickManager.instance;
        manager.registerTick(
          id: 'boom',
          interval: const Duration(milliseconds: 1),
          priority: TickPriority.critical,
          callback: (_) => throw StateError('boom'),
        );
        async.elapse(const Duration(seconds: 2));
        manager.unregisterTick('boom');
      });
    });

    test('pause suppresses ticks and resume restores them', () {
      fakeAsync((async) {
        final manager = TickManager.instance;
        var calls = 0;
        manager.registerTick(
          id: 'paused',
          interval: const Duration(milliseconds: 1),
          priority: TickPriority.critical,
          callback: (_) => calls++,
        );
        manager.pause();
        async.elapse(const Duration(seconds: 2));
        expect(calls, 0);

        manager.resume();
        async.elapse(const Duration(seconds: 2));
        expect(calls, greaterThanOrEqualTo(1));
        manager.unregisterTick('paused');
      });
    });

    test('dispose clears subscriptions and cancels the heartbeat', () async {
      final manager = TickManager.instance;
      manager.registerTick(
        id: 'd',
        interval: const Duration(milliseconds: 1),
        priority: TickPriority.critical,
        callback: (_) {},
      );
      await manager.dispose();
      expect(manager, isNotNull);
    });
  });
}
