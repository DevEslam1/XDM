import 'package:dmx/core/services/widget_data_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Widget Payload Capping & Aggregation Tests [W-3]', () {
    test(
        'WidgetDashboard.fromTasks caps to 20 tasks and recomputes all aggregates from the capped slice',
        () {
      final tasks = List.generate(
        30,
        (i) => WidgetTaskSummary(
          id: 'task_$i',
          fileName: 'file_$i.zip',
          status: i < 10 ? 'downloading' : (i < 25 ? 'queued' : 'completed'),
          progress: 0.1 * (i % 10),
          speedBytesPerSec: i < 10 ? 1024 * 1024 : 0,
          fileSizeBytes: 10 * 1024 * 1024,
          downloadedBytes: 1 * 1024 * 1024,
          category: 'Archive',
          isTorrent: false,
          priority: i,
          isAppUpdate: false,
          speedTrend: 'stable',
        ),
      );

      final dashboard = WidgetDashboard.fromTasks(
        tasks,
        availableStorageBytes: 50 * 1024 * 1024 * 1024,
        isOnWifi: true,
        completedTodayCount: 5,
      );

      // Capped length must be exactly 20
      expect(dashboard.tasks.length, equals(20));

      // Aggregates must strictly reflect the 20 capped tasks
      var expectedSpeed = 0;
      var expectedActive = 0;
      var expectedDownloaded = 0;
      var expectedFileSize = 0;
      var expectedFailed = 0;

      for (final t in dashboard.tasks) {
        if (t.status == 'downloading' || t.status == 'seeding') {
          expectedActive++;
          if (t.status == 'downloading') expectedSpeed += t.speedBytesPerSec;
        }
        expectedDownloaded += t.downloadedBytes;
        expectedFileSize += t.fileSizeBytes;
        if (t.status == 'failed') expectedFailed++;
      }

      expect(dashboard.totalActiveCount, equals(expectedActive));
      expect(dashboard.totalSpeedBytesPerSec, equals(expectedSpeed));
      expect(dashboard.totalDownloadedBytes, equals(expectedDownloaded));
      expect(dashboard.totalFileSizeBytes, equals(expectedFileSize));
      expect(dashboard.failedCount, equals(expectedFailed));
    });
  });
}
