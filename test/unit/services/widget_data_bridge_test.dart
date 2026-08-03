import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/widget_data_bridge.dart';

WidgetTaskSummary task(
  String id, {
  String status = 'downloading',
  double progress = 0.5,
  int speed = 0,
  int? eta,
  int priority = 0,
  bool isAppUpdate = false,
  String fileName = 'file',
}) =>
    WidgetTaskSummary(
      id: id,
      fileName: fileName,
      status: status,
      progress: progress,
      speedBytesPerSec: speed,
      etaSeconds: eta,
      fileSizeBytes: 1000,
      downloadedBytes: 500,
      category: 'Other',
      isTorrent: false,
      priority: priority,
      isAppUpdate: isAppUpdate,
      speedTrend: 'stable',
    );

WidgetDashboard dashboard(List<WidgetTaskSummary> tasks) =>
    WidgetDashboard.fromTasks(
      tasks,
      availableStorageBytes: 10 * 1024 * 1024 * 1024,
      isOnWifi: true,
      completedTodayCount: 3,
    );

void main() {
  group('WidgetDashboard.fromTasks sorting', () {
    test('sorts failed first, then app updates, then active by priority', () {
      final result = dashboard([
        task('completed', status: 'completed'),
        task('paused', status: 'paused'),
        task('failed', status: 'failed'),
        task('app-update', status: 'downloading', isAppUpdate: true),
        task('high', status: 'downloading', priority: 5),
        task('low', status: 'downloading', priority: 1),
        task('queued', status: 'queued'),
      ]);

      expect(
        result.tasks.map((t) => t.id).toList(),
        ['failed', 'app-update', 'high', 'low', 'queued', 'paused', 'completed'],
      );
    });

    test('aggregates active count, total speed and failures', () {
      final result = dashboard([
        task('a', speed: 1000),
        task('b', speed: 2000, priority: 9),
        task('c', status: 'seeding'),
        task('d', status: 'failed'),
        task('e', status: 'paused'),
      ]);

      expect(result.totalActiveCount, 3);
      expect(result.totalSpeedBytesPerSec, 3000);
      expect(result.failedCount, 1);
      expect(result.completedTodayCount, 3);
    });

    test('seeding tasks count as active but do not add speed', () {
      final result = dashboard([
        task('seed', status: 'seeding', speed: 999),
      ]);
      expect(result.totalActiveCount, 1);
      expect(result.totalSpeedBytesPerSec, 0);
    });
  });

  group('calculateSpeedTrend', () {
    test('up when current exceeds previous by 10%', () {
      expect(
        WidgetDataBridge.calculateSpeedTrend([100, 120]),
        'up',
      );
    });

    test('down when current drops below 90% of previous', () {
      expect(
        WidgetDataBridge.calculateSpeedTrend([100, 80]),
        'down',
      );
    });

    test('stable otherwise or with too few samples', () {
      expect(WidgetDataBridge.calculateSpeedTrend([100, 105]), 'stable');
      expect(WidgetDataBridge.calculateSpeedTrend([100]), 'stable');
      expect(WidgetDataBridge.calculateSpeedTrend(const []), 'stable');
    });
  });

  group('calculateEta and formatEta', () {
    test('eta is remaining bytes over speed', () {
      expect(WidgetDataBridge.calculateEta(10 * 1024, 1024), 10);
    });

    test('eta is null when stalled or nothing remains', () {
      expect(WidgetDataBridge.calculateEta(100, 0), isNull);
      expect(WidgetDataBridge.calculateEta(0, 100), isNull);
    });

    test('formatEta renders compact labels', () {
      expect(WidgetDataBridge.formatEta(null), '--');
      expect(WidgetDataBridge.formatEta(0), '--');
      expect(WidgetDataBridge.formatEta(30), 'Almost done');
      expect(WidgetDataBridge.formatEta(240), '~4 min');
      expect(WidgetDataBridge.formatEta(3665), '~1h 1m');
      expect(WidgetDataBridge.formatEta(7200), '~2h');
    });
  });

  group('storage thresholds', () {
    test('low and critical thresholds', () {
      expect(WidgetDataBridge.isStorageLow(499 * 1024 * 1024), isTrue);
      expect(WidgetDataBridge.isStorageLow(500 * 1024 * 1024), isFalse);
      expect(WidgetDataBridge.isStorageLow(-1), isFalse);
      expect(WidgetDataBridge.isStorageCritical(99 * 1024 * 1024), isTrue);
      expect(WidgetDataBridge.isStorageCritical(500 * 1024 * 1024), isFalse);
    });
  });

  group('pushDashboard throttling', () {
    test('pushing within the interval is delayed until it elapses', () async {
      final pushes = <WidgetDashboard>[];
      WidgetDataBridge.testSink = (d) async => pushes.add(d);

      try {
        final bridge = WidgetDataBridge.instance;
        final snapshots = dashboard([task('a', speed: 100)]);

        await bridge.pushDashboard(snapshots);
        await bridge.pushDashboard(snapshots);
        expect(pushes.length, 1);

        await Future<void>.delayed(
          WidgetDataBridge.minPushInterval + const Duration(seconds: 1),
        );
        expect(pushes.length, 2);
      } finally {
        WidgetDataBridge.testSink = null;
      }
    });

    test('force bypasses the throttle', () async {
      final pushes = <WidgetDashboard>[];
      WidgetDataBridge.testSink = (d) async => pushes.add(d);

      try {
        final bridge = WidgetDataBridge.instance;
        final snapshots = dashboard([task('a', speed: 100)]);

        await bridge.pushDashboard(snapshots, force: true);
        await bridge.pushDashboard(snapshots, force: true);
        expect(pushes.length, 2);
      } finally {
        WidgetDataBridge.testSink = null;
      }
    });
  });
}
