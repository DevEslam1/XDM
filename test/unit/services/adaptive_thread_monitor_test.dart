import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/engines/http_download_engine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HttpDownloadEngine adaptive thread monitor (H4)', () {
    late HttpDownloadEngine engine;

    setUp(() {
      engine = HttpDownloadEngine();
      DownloadEngine.appInForeground = true;
    });

    tearDown(() {
      engine.stopAdaptiveThreadMonitor();
    });

    test('trackers are created and stopFor removes them (no leak)', () {
      engine.startAdaptiveMonitorForTask('a', 8);
      engine.startAdaptiveMonitorForTask('b', 4);
      expect(engine.activeTrackerCount, 2);

      engine.stopFor('a');
      expect(engine.activeTrackerCount, 1);

      engine.stopFor('b');
      expect(engine.activeTrackerCount, 0);
    });

    test('repeated start/stop cycles do not accumulate trackers', () {
      for (var i = 0; i < 100; i++) {
        engine.startAdaptiveMonitorForTask('leak-$i', 8);
        engine.stopFor('leak-$i');
      }
      expect(engine.activeTrackerCount, 0);
    });

    test('startAdaptiveMonitorIfEnabled respects the enabled flag', () {
      final task = createTestTask(id: 't1', threadCount: 8);
      engine.startAdaptiveMonitorIfEnabled(task, false);
      expect(engine.activeTrackerCount, 0);

      engine.startAdaptiveMonitorIfEnabled(task, true);
      expect(engine.activeTrackerCount, 1);
    });

    test('recommendedThreads returns fallback when tracker is absent', () {
      expect(engine.recommendedThreads('ghost', 8), 8);
      expect(engine.recommendedThreads('ghost', 2), 2);
    });

    test('recordSample ignores non-positive throughput', () {
      engine.startAdaptiveMonitorForTask('t2', 8);
      engine.recordSample('t2', -100, 8);
      engine.recordSample('t2', 0, 8);
      // No samples → no recommendation, fallback wins.
      expect(engine.recommendedThreads('t2', 8), 8);
    });

    test('plateau detection recommends fewer threads after stable speed',
        () {
      fakeAsync((async) {
        engine.startAdaptiveMonitorForTask('t3', 8);
        for (var i = 0; i < 6; i++) {
          engine.recordSample('t3', 4 * 1024 * 1024, 8);
        }
        // Let the periodic monitor tick fire and evaluate.
        async.elapse(const Duration(seconds: 6));
        final rec = engine.recommendedThreads('t3', 8);
        expect(rec, lessThan(8));
        expect(rec, greaterThanOrEqualTo(1));
      });
    });

    test('updateTrackerThreadCount resets a stale recommendation', () {
      fakeAsync((async) {
        engine.startAdaptiveMonitorForTask('t4', 8);
        for (var i = 0; i < 6; i++) {
          engine.recordSample('t4', 4 * 1024 * 1024, 8);
        }
        async.elapse(const Duration(seconds: 6));
        expect(engine.recommendedThreads('t4', 8), lessThan(8));

        // Restart with a different thread count → recommendation cleared.
        engine.updateTrackerThreadCount('t4', 16);
        expect(engine.recommendedThreads('t4', 16), 16);
      });
    });

    test('pauseAll cancels the monitor and resumeAll restarts it', () {
      fakeAsync((async) {
        engine.startAdaptiveMonitorForTask('t5', 8);
        for (var i = 0; i < 6; i++) {
          engine.recordSample('t5', 4 * 1024 * 1024, 8);
        }
        engine.pauseAll();
        // Timer is cancelled: elapsing time should not evaluate.
        async.elapse(const Duration(seconds: 30));
        expect(engine.recommendedThreads('t5', 8), 8);

        engine.resumeAll();
        async.elapse(const Duration(seconds: 6));
        expect(engine.recommendedThreads('t5', 8), lessThan(8));
      });
    });

    test('evaluate clears recommendation when samples count is less than 6', () {
      fakeAsync((async) {
        engine.startAdaptiveMonitorForTask('t6', 8);
        for (var i = 0; i < 3; i++) {
          engine.recordSample('t6', 4 * 1024 * 1024, 8);
        }
        async.elapse(const Duration(seconds: 6));
        expect(engine.recommendedThreads('t6', 8), 8);
      });
    });

    test('stopAdaptiveThreadMonitor clears all trackers', () {
      engine.startAdaptiveMonitorForTask('x', 8);
      engine.startAdaptiveMonitorForTask('y', 4);
      engine.stopAdaptiveThreadMonitor();
      expect(engine.activeTrackerCount, 0);
      expect(engine.recommendedThreads('x', 8), 8);
    });
  });
}
