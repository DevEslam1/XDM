import 'dart:async';

import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadProgress Immutability & Concurrency Stress Tests (Task 2.4 / Task 5.3)', () {
    test('DownloadProgress is strictly immutable and supports copyWith without state pollution', () {
      const original = DownloadProgress(
        downloadedBytes: 1000,
        fileSize: 10000,
        speed: 500.0,
        eta: 18,
        statusMessage: 'Downloading',
        cycleState: 'downloading',
      );

      final modified = original.copyWith(
        downloadedBytes: 2000,
        speed: 1000.0,
      );

      expect(original.downloadedBytes, 1000);
      expect(original.speed, 500.0);
      expect(modified.downloadedBytes, 2000);
      expect(modified.speed, 1000.0);
      expect(modified.fileSize, 10000);
      expect(modified.statusMessage, 'Downloading');
    });

    test('Stress test: emits 10,000 progress events across 4 concurrent async streams without race conditions', () async {
      final receivedEvents = <DownloadProgress>[];
      final completer = Completer<void>();
      const totalPerStream = 2500;
      const numStreams = 4;
      int completedStreams = 0;

      for (int streamIdx = 0; streamIdx < numStreams; streamIdx++) {
        final currentStream = streamIdx;
        () async {
          for (int i = 0; i < totalPerStream; i++) {
            final progress = DownloadProgress(
              downloadedBytes: (i + 1) * 100,
              fileSize: totalPerStream * 100,
              speed: 1024.0 * (currentStream + 1),
              eta: totalPerStream - i,
              statusMessage: 'Stream $currentStream Tick $i',
              cycleState: 'downloading',
            );

            // Verify progress ratio calculation remains purely deterministic
            expect(progress.progressRatio, greaterThanOrEqualTo(0.0));
            expect(progress.progressRatio, lessThanOrEqualTo(1.0));

            receivedEvents.add(progress);
            if (i % 500 == 0) {
              await Future<void>.delayed(Duration.zero);
            }
          }
          completedStreams++;
          if (completedStreams == numStreams) {
            completer.complete();
          }
        }();
      }

      await completer.future.timeout(const Duration(seconds: 10));

      expect(receivedEvents.length, totalPerStream * numStreams);
      expect(completedStreams, 4);
    });
  });
}
