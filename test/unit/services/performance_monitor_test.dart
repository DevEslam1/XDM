import 'dart:ui' show FrameTiming;

import 'package:dmx/core/services/performance_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late PerformanceMonitor monitor;

  setUp(() {
    monitor = PerformanceMonitor();
    monitor.reset();
  });

  FrameTiming frame({required int buildUs, int rasterUs = 4000}) {
    // Durations are computed as (finish - start); start at 0 for simplicity.
    return FrameTiming(
      vsyncStart: 0,
      buildStart: 0,
      buildFinish: buildUs,
      rasterStart: 0,
      rasterFinish: rasterUs,
      rasterFinishWallTime: rasterUs,
    );
  }

  test('records frame counts and averages', () {
    monitor.ingestFrameTimings([
      frame(buildUs: 8000),
      frame(buildUs: 10000),
      frame(buildUs: 12000),
    ]);
    expect(monitor.totalFrames, 3);
    expect(monitor.sampleCount, 3);
    expect(monitor.averageBuildMillis, closeTo(10.0, 0.01));
    expect(monitor.averageRasterMillis, closeTo(4.0, 0.01));
  });

  test('flags frames above the jank threshold', () {
    monitor.ingestFrameTimings([
      frame(buildUs: 8000), // fast
      frame(buildUs: 25000), // janky (>16ms)
      frame(buildUs: 40000), // janky
    ]);
    expect(monitor.jankyFrameCount, 2);
    expect(monitor.jankRatio, closeTo(2 / 3, 0.001));
  });

  test('keeps only the bounded sample window', () {
    final frames = List<FrameTiming>.generate(
      PerformanceMonitor.maxSamples + 100,
      (i) => frame(buildUs: 8000),
    );
    monitor.ingestFrameTimings(frames);
    expect(monitor.sampleCount, PerformanceMonitor.maxSamples);
    // Total frame count still reflects everything observed.
    expect(monitor.totalFrames, PerformanceMonitor.maxSamples + 100);
  });

  test('empty monitor reports zero and null averages', () {
    expect(monitor.totalFrames, 0);
    expect(monitor.jankyFrameCount, 0);
    expect(monitor.jankRatio, 0.0);
    expect(monitor.averageBuildMillis, isNull);
  });

  test('reset clears all state', () {
    monitor.ingestFrameTimings([frame(buildUs: 30000)]);
    monitor.reset();
    expect(monitor.totalFrames, 0);
    expect(monitor.sampleCount, 0);
  });
}
