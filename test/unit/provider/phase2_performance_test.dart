import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/tick_manager.dart';
import 'package:dmx/features/downloads/models/download_state_machine.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_list_provider.dart';
import 'package:dmx/features/downloads/provider/download_stats_notifier.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dmx/features/downloads/data/task_repository.dart';

class MockTaskRepository extends Mock implements TaskRepository {}

DownloadTask createDummyTask({
  required String id,
  DownloadStatus status = DownloadStatus.queued,
  int downloadedBytes = 0,
  double speed = 0.0,
}) {
  final now = DateTime.now();
  return DownloadTask(
    id: id,
    fileName: '$id.bin',
    url: 'https://example.com/$id.bin',
    fileSize: 1000,
    downloadedBytes: downloadedBytes,
    speed: speed,
    category: 'Other',
    status: status,
    savePath: '/downloads',
    localFilePath: '/downloads/$id.bin',
    tempFilePath: '/downloads/$id.bin.part',
    threadCount: 1,
    chunks: const [0.0],
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(createDummyTask(id: 'fallback'));
  });

  group('Phase 2.3: State Machine & transitionTo Validation', () {
    test('transitionTo executes valid transitions smoothly', () {
      final task = createDummyTask(id: 't-1', status: DownloadStatus.queued);
      final downloading = task.transitionTo(
        DownloadStatus.downloading,
        reason: 'queue pump',
        speed: 1024,
      );

      expect(downloading.status, DownloadStatus.downloading);
      expect(downloading.speed, 1024);

      final paused = downloading.transitionTo(
        DownloadStatus.paused,
        reason: 'user requested',
      );
      expect(paused.status, DownloadStatus.paused);

      final completed = downloading.transitionTo(
        DownloadStatus.completed,
        reason: 'finished 100%',
      );
      expect(completed.status, DownloadStatus.completed);
    });

    test('canTransitionStatus matches allowed state matrix', () {
      expect(
        DownloadStateMachine.canTransitionStatus(
          DownloadStatus.queued,
          DownloadStatus.downloading,
        ),
        isTrue,
      );

      expect(
        DownloadStateMachine.canTransitionStatus(
          DownloadStatus.downloading,
          DownloadStatus.paused,
        ),
        isTrue,
      );

      expect(
        DownloadStateMachine.canTransitionStatus(
          DownloadStatus.downloading,
          DownloadStatus.completed,
        ),
        isTrue,
      );
    });
  });

  group('Phase 2.2: DownloadStatsNotifier Aggregation', () {
    late MockTaskRepository mockRepo;
    late DownloadListProvider listProvider;
    late DownloadStatsNotifier statsNotifier;

    setUp(() {
      mockRepo = MockTaskRepository();
      when(() => mockRepo.save(any())).thenAnswer((_) async {});
      listProvider = DownloadListProvider(mockRepo);
      statsNotifier = DownloadStatsNotifier(listProvider);
    });

    tearDown(() {
      statsNotifier.dispose();
      listProvider.dispose();
    });

    test('recalculates aggregate statistics without rebuilding list', () async {
      expect(statsNotifier.activeCount, 0);
      expect(statsNotifier.totalDownloadSpeed, 0.0);

      final task1 = createDummyTask(
        id: 't-1',
        status: DownloadStatus.downloading,
        downloadedBytes: 200,
        speed: 500.0,
      );
      final task2 = createDummyTask(
        id: 't-2',
        status: DownloadStatus.downloading,
        downloadedBytes: 300,
        speed: 700.0,
      );
      final task3 = createDummyTask(
        id: 't-3',
        status: DownloadStatus.completed,
        downloadedBytes: 1000,
      );

      await listProvider.addTask(task1);
      await listProvider.addTask(task2);
      await listProvider.addTask(task3);

      expect(statsNotifier.activeCount, 2);
      expect(statsNotifier.completedCount, 1);
      expect(statsNotifier.totalDownloadSpeed, 1200.0);
      expect(statsNotifier.totalDownloadedBytes, 1500);
    });
  });

  group('Phase 2.5: TickManager Centralization', () {
    tearDown(() {
      TickManager.instance.unregisterTick('test-tick-critical');
      TickManager.instance.unregisterTick('test-tick-normal');
    });

    test('registers and fires tick subscribers', () async {
      var criticalTicks = 0;
      var normalTicks = 0;

      TickManager.instance.registerTick(
        id: 'test-tick-critical',
        interval: const Duration(milliseconds: 100),
        priority: TickPriority.critical,
        callback: (_) => criticalTicks++,
      );

      TickManager.instance.registerTick(
        id: 'test-tick-normal',
        interval: const Duration(milliseconds: 100),
        priority: TickPriority.normal,
        callback: (_) => normalTicks++,
      );

      await Future.delayed(const Duration(milliseconds: 700));

      expect(criticalTicks, greaterThan(0));
      expect(normalTicks, greaterThan(0));
    });
  });
}
