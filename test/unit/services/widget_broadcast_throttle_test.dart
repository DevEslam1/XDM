import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Widget Broadcast Throttle & Synchronization Tests [W-2]', () {
    test(
        'WidgetDataRepository synchronizes throttle state and uses failedCount delta',
        () {
      final repoFile = File(
          'android/app/src/main/kotlin/com/xdm/downloadmanager/widget/WidgetDataRepository.kt');
      expect(repoFile.existsSync(), isTrue);
      final content = repoFile.readAsStringSync();

      // W-2 (a): Verify failedCount integer comparison instead of boolean hasFailures
      expect(content.contains('dashboard?.hasFailures == true'), isFalse);
      expect(content.contains('failedCount != lastFailedCount'), isTrue);

      // W-2 (b): Verify synchronized block and @Volatile qualifiers on throttle state
      expect(content.contains('@Volatile'), isTrue);
      expect(content.contains('synchronized(this)'), isTrue);
    });

    test(
        'Simulated throttle logic avoids continuous broadcast spam during sustained failures',
        () {
      var lastBroadcastTime = 0;
      var lastTotalProgress = 0.0;
      var lastTotalDownloaded = 0;
      var lastActiveCount = 0;
      var lastFailedCount = 0;
      var broadcastCount = 0;

      void processSave({
        required int now,
        required double progress,
        required int downloaded,
        required int activeCount,
        required int failedCount,
        bool force = false,
      }) {
        final progressDelta = (progress - lastTotalProgress).abs();
        final bytesDelta = (downloaded - lastTotalDownloaded).abs();
        final stateChanged =
            activeCount != lastActiveCount || failedCount != lastFailedCount;
        final shouldBroadcast = force ||
            stateChanged ||
            (now - lastBroadcastTime >= 2000 &&
                (progressDelta >= 0.01 || bytesDelta >= 64 * 1024));

        if (shouldBroadcast) {
          lastBroadcastTime = now;
          lastTotalProgress = progress;
          lastTotalDownloaded = downloaded;
          lastActiveCount = activeCount;
          lastFailedCount = failedCount;
          broadcastCount++;
        }
      }

      // Initial task failure -> State changed -> Broadcasts once
      processSave(
          now: 1000,
          progress: 0.5,
          downloaded: 1000,
          activeCount: 1,
          failedCount: 1);
      expect(broadcastCount, equals(1));

      // Subsequent saves with NO delta while failure persists -> Must NOT bypass throttle
      processSave(
          now: 1100,
          progress: 0.5,
          downloaded: 1000,
          activeCount: 1,
          failedCount: 1);
      processSave(
          now: 1200,
          progress: 0.5,
          downloaded: 1000,
          activeCount: 1,
          failedCount: 1);
      processSave(
          now: 1300,
          progress: 0.5,
          downloaded: 1000,
          activeCount: 1,
          failedCount: 1);
      expect(broadcastCount, equals(1),
          reason: 'Ongoing failure without delta should be throttled');

      // A second task fails -> State changed -> Broadcasts
      processSave(
          now: 1400,
          progress: 0.5,
          downloaded: 1000,
          activeCount: 1,
          failedCount: 2);
      expect(broadcastCount, equals(2),
          reason:
              'Failure count increment should trigger state-change broadcast');
    });
  });
}
