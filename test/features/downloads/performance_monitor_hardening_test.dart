import 'package:dmx/core/services/performance_monitor.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  FrameTiming makeFrame({required int buildUs, int rasterUs = 4000}) {
    return FrameTiming(
      vsyncStart: 0,
      buildStart: 0,
      buildFinish: buildUs,
      rasterStart: 0,
      rasterFinish: rasterUs,
      rasterFinishWallTime: rasterUs,
    );
  }

  group('PerformanceMonitor Hardening (Sprint 4)', () {
    test('Consecutive janky frames trigger auto-degrade callback', () {
      final monitor = PerformanceMonitor();
      monitor.reset();
      var autoDegradeTriggered = false;

      PerformanceMonitor.onAutoDegradeTriggered = () {
        autoDegradeTriggered = true;
      };

      // Feed 5 janky frames (build > 35ms)
      for (int i = 0; i < 5; i++) {
        monitor.ingestFrameTimings([
          makeFrame(buildUs: 35000),
        ]);
      }

      expect(autoDegradeTriggered, isTrue);
      PerformanceMonitor.onAutoDegradeTriggered = null;
    });
  });
}
