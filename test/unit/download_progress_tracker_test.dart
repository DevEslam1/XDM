import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/features/downloads/provider/download_progress_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadProgressTracker deduplication tests', () {
    test('updateProgress notifies listeners on distinct progress update', () {
      final tracker = DownloadProgressTracker();
      int notifyCount = 0;
      tracker.addListener(() => notifyCount++);

      const progress1 = DownloadProgress(
        downloadedBytes: 1000,
        fileSize: 5000,
        speed: 250.0,
        eta: 16,
      );

      tracker.updateProgress('task-1', progress1);

      expect(notifyCount, equals(1));
      expect(tracker.getProgressData('task-1'), equals(progress1));
      expect(tracker.getProgress('task-1').value, closeTo(0.2, 0.001));
      expect(tracker.getSpeed('task-1').value, equals(250.0));
    });

    test('updateProgress does not notify listeners when progress is unchanged',
        () {
      final tracker = DownloadProgressTracker();
      int notifyCount = 0;
      tracker.addListener(() => notifyCount++);

      const progress = DownloadProgress(
        downloadedBytes: 2500,
        fileSize: 5000,
        speed: 500.0,
        eta: 5,
      );

      // First update triggers notification
      tracker.updateProgress('task-1', progress);
      expect(notifyCount, equals(1));

      // Duplicate update should be deduplicated
      tracker.updateProgress('task-1', progress);
      expect(notifyCount, equals(1));

      // Slightly different update triggers notification
      const progressNext = DownloadProgress(
        downloadedBytes: 3000,
        fileSize: 5000,
        speed: 500.0,
        eta: 4,
      );
      tracker.updateProgress('task-1', progressNext);
      expect(notifyCount, equals(2));
    });
  });
}
