import 'dart:async';

import 'package:dmx/core/services/background_gate.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/features/downloads/data/task_repository.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_list_provider.dart';
import 'package:dmx/features/downloads/provider/download_queue_provider.dart';
import 'package:dmx/features/downloads/usecases/cancel_download_usecase.dart';
import 'package:dmx/features/downloads/usecases/delete_download_usecase.dart';
import 'package:dmx/features/downloads/usecases/pause_download_usecase.dart';
import 'package:dmx/features/downloads/usecases/resume_download_usecase.dart';
import 'package:dmx/features/downloads/usecases/retry_download_usecase.dart';
import 'package:dmx/features/downloads/usecases/start_download_usecase.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/shared/mixins/pausable_loop_animation.dart';
import 'package:dmx/shared/widgets/dmx_backdrop_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _MockTaskRepo implements TaskRepository {
  final Map<String, DownloadTask> _store = {};
  final StreamController<DownloadTask> _taskStreamController =
      StreamController<DownloadTask>.broadcast();

  @override
  Future<List<DownloadTask>> getAll() async => _store.values.toList();

  @override
  Future<DownloadTask?> getById(String id) async => _store[id];

  @override
  Future<void> save(DownloadTask task) async {
    _store[task.id] = task;
    _taskStreamController.add(task);
  }

  @override
  Future<void> saveAll(List<DownloadTask> tasks) async {
    for (final t in tasks) {
      _store[t.id] = t;
      _taskStreamController.add(t);
    }
  }

  @override
  Future<void> delete(String id) async {
    _store.remove(id);
  }

  @override
  Future<void> deleteAll(List<String> ids) async {
    for (final id in ids) {
      _store.remove(id);
    }
  }

  @override
  Stream<DownloadTask> watchTask(String id) =>
      _taskStreamController.stream.where((t) => t.id == id);
}

DownloadTask _makeTask({
  required String id,
  required String fileName,
  required String url,
  required int fileSize,
  required DownloadStatus status,
  int downloadedBytes = 0,
}) {
  final now = DateTime.now();
  return DownloadTask(
    id: id,
    fileName: fileName,
    url: url,
    fileSize: fileSize,
    downloadedBytes: downloadedBytes,
    category: 'other',
    status: status,
    savePath: '/downloads',
    localFilePath: '/downloads/$fileName',
    tempFilePath: '/downloads/$id.tmp',
    threadCount: 2,
    chunks: const [0.0, 0.0],
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Audit Remediation: GPU & Visuals Hardening', () {
    setUp(() {
      DmxBackdropFilter.resetActiveCount();
      DownloadEngine.appInForeground = true;
    });

    tearDown(() {
      DmxBackdropFilter.resetActiveCount();
      DownloadEngine.appInForeground = true;
    });

    testWidgets(
        'DmxBackdropFilter renders solid Container when appInForeground is false',
        (tester) async {
      DownloadEngine.appInForeground = false;
      expect(BackgroundGate.allowHeavyOps, isFalse);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: SettingsProvider.instance,
          child: const MaterialApp(
            home: Scaffold(
              body: DmxBackdropFilter(
                sigmaX: 15,
                sigmaY: 15,
                child: Text('Background Test'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Background Test'), findsOneWidget);
      // BackdropFilter should NOT have incremented active count when allowHeavyOps is false
      expect(DmxBackdropFilter.activeCount, equals(0));
    });

    testWidgets(
        'modernAnimationsAllowed returns false when allowHeavyOps is false',
        (tester) async {
      DownloadEngine.appInForeground = false;
      expect(BackgroundGate.allowHeavyOps, isFalse);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: SettingsProvider.instance,
          child: Builder(
            builder: (context) {
              final allowed = modernAnimationsAllowed(context);
              expect(allowed, isFalse);
              return const SizedBox();
            },
          ),
        ),
      );
    });
  });

  group('Audit Remediation: Clean Architecture Use Cases', () {
    late _MockTaskRepo repo;
    late DownloadListProvider listProvider;
    late DownloadQueueProvider queueProvider;

    setUp(() async {
      repo = _MockTaskRepo();
      listProvider = DownloadListProvider(repo);
      queueProvider = DownloadQueueProvider(
          listProvider: listProvider, maxConcurrentDownloads: 2);
    });

    test('StartDownloadUseCase adds task to list and queues it', () async {
      final useCase = StartDownloadUseCase(listProvider, queueProvider);
      final task = _makeTask(
        id: 'task-1',
        url: 'https://example.com/file.zip',
        fileName: 'file.zip',
        fileSize: 1024,
        status: DownloadStatus.queued,
      );

      await useCase(task);

      expect(listProvider.tasks.length, equals(1));
      expect(listProvider.tasks.first.id, equals('task-1'));
    });

    test(
        'PauseDownloadUseCase and ResumeDownloadUseCase transition task statuses',
        () async {
      final startUseCase = StartDownloadUseCase(listProvider, queueProvider);
      final pauseUseCase = PauseDownloadUseCase(queueProvider);
      final resumeUseCase = ResumeDownloadUseCase(queueProvider);

      final task = _makeTask(
        id: 'task-2',
        url: 'https://example.com/file2.zip',
        fileName: 'file2.zip',
        fileSize: 2048,
        downloadedBytes: 500,
        status: DownloadStatus.downloading,
      );

      await startUseCase(task);
      expect(listProvider.findTask('task-2')?.status,
          equals(DownloadStatus.downloading));

      await pauseUseCase('task-2');
      expect(listProvider.findTask('task-2')?.status,
          equals(DownloadStatus.paused));

      await resumeUseCase('task-2');
      expect(listProvider.findTask('task-2')?.status,
          isNot(equals(DownloadStatus.paused)));
    });

    test('CancelDownloadUseCase marks task failed with cancellation message',
        () async {
      final startUseCase = StartDownloadUseCase(listProvider, queueProvider);
      final cancelUseCase = CancelDownloadUseCase(listProvider);

      final task = _makeTask(
        id: 'task-3',
        url: 'https://example.com/file3.zip',
        fileName: 'file3.zip',
        fileSize: 4096,
        downloadedBytes: 1000,
        status: DownloadStatus.downloading,
      );

      await startUseCase(task);
      await cancelUseCase('task-3');

      final updated = listProvider.findTask('task-3');
      expect(updated?.status, equals(DownloadStatus.failed));
      expect(updated?.errorMessage, contains('Cancelled'));
    });

    test('RetryDownloadUseCase resets error and enqueues task', () async {
      final startUseCase = StartDownloadUseCase(listProvider, queueProvider);
      final retryUseCase = RetryDownloadUseCase(listProvider, queueProvider);

      final task = _makeTask(
        id: 'task-retry',
        url: 'https://example.com/retry.zip',
        fileName: 'retry.zip',
        fileSize: 4096,
        downloadedBytes: 500,
        status: DownloadStatus.failed,
      );

      await startUseCase(task);
      await retryUseCase('task-retry');

      final updated = listProvider.findTask('task-retry');
      expect(updated?.status, isNot(equals(DownloadStatus.failed)));
      expect(updated?.errorMessage, isNull);
    });

    test('DeleteDownloadUseCase removes task from repository and list',
        () async {
      final startUseCase = StartDownloadUseCase(listProvider, queueProvider);
      final deleteUseCase = DeleteDownloadUseCase(listProvider);

      final task = _makeTask(
        id: 'task-4',
        url: 'https://example.com/file4.zip',
        fileName: 'file4.zip',
        fileSize: 8192,
        status: DownloadStatus.queued,
      );

      await startUseCase(task);
      expect(listProvider.tasks.length, equals(1));

      await deleteUseCase('task-4');
      expect(listProvider.tasks.isEmpty, isTrue);
    });
  });

  group('Audit Remediation: StateStore & Chunks Normalization', () {
    test(
        'TransferState.tryParseV3 normalizes threadCount to chunk array length safely',
        () {
      final json = {
        'version': 3,
        'v': 3,
        'totalSize': 1000,
        'threadCount': 8, // Mismatch with actual chunks length (2)
        'chunks': [
          {'start': 0, 'end': 499, 'downloaded': 100},
          {'start': 500, 'end': 999, 'downloaded': 200},
        ],
        'status': 'active',
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      };

      final state = TransferState.tryParseV3(json);
      expect(state, isNotNull);
      expect(state!.chunks.length, equals(2));
      expect(state.downloadedBytes, equals(300));
    });
  });
}
