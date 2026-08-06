import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';

class _MockOrchestratorHost implements DownloadOrchestratorHost {
  DownloadTask? lastTaskState;

  @override
  Future<void> setTaskState(DownloadTask task) async {
    lastTaskState = task;
  }

  @override
  void pushProgressTick(String taskId, double progress, double speed) {}

  @override
  bool get enableBackgroundTimers => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockOrchestratorHost mockHost;
  late DownloadOrchestrator orchestrator;
  late Directory tempDir;

  setUp(() async {
    mockHost = _MockOrchestratorHost();
    orchestrator = DownloadOrchestrator(mockHost);
    tempDir = await Directory.systemTemp.createTemp('dmx_engine_test');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Resume State Validation Tests', () {
    test('resets progress on corrupt state file', () async {
      final taskFile = File('${tempDir.path}/task.iso');
      await taskFile.writeAsString('partial-content');
      final stateFile = File('${tempDir.path}/task.iso.dmxstate');
      await stateFile.writeAsString('{invalid-json}');

      final task = DownloadTask(
        id: 't_corrupt',
        fileName: 'task.iso',
        url: 'https://example.com/task.iso',
        fileSize: 10000,
        downloadedBytes: 500,
        category: 'OS',
        status: DownloadStatus.paused,
        savePath: tempDir.path,
        localFilePath: taskFile.path,
        tempFilePath: taskFile.path,
        threadCount: 2,
        chunks: const [0.05, 0.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final result = await orchestrator.validateResumeState(task);

      expect(result.downloadedBytes, equals(0));
      expect(result.chunks.every((c) => c == 0.0), isTrue);
      expect(await stateFile.exists(), isFalse);
      expect(mockHost.lastTaskState, isNotNull);
      expect(mockHost.lastTaskState!.downloadedBytes, equals(0));
    });

    test('resets progress on size mismatch', () async {
      final taskFile = File('${tempDir.path}/task.iso');
      await taskFile.writeAsString('partial-content');
      final stateFile = File('${tempDir.path}/task.iso.dmxstate');
      await stateFile.writeAsString(jsonEncode({'totalSize': 5000}));

      final task = DownloadTask(
        id: 't_mismatch',
        fileName: 'task.iso',
        url: 'https://example.com/task.iso',
        fileSize: 10000, // task expects 10000 but state file has 5000
        downloadedBytes: 500,
        category: 'OS',
        status: DownloadStatus.paused,
        savePath: tempDir.path,
        localFilePath: taskFile.path,
        tempFilePath: taskFile.path,
        threadCount: 2,
        chunks: const [0.05, 0.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final result = await orchestrator.validateResumeState(task);

      expect(result.downloadedBytes, equals(0));
      expect(result.chunks.every((c) => c == 0.0), isTrue);
      expect(await stateFile.exists(), isFalse);
    });

    test('retains progress when state is valid and sizes match', () async {
      final taskFile = File('${tempDir.path}/task.iso');
      await taskFile.writeAsBytes(List.filled(500, 0));
      final stateFile = File('${tempDir.path}/task.iso.dmxstate');
      await stateFile.writeAsString(jsonEncode({
        'totalSize': 10000,
        'threadCount': 2,
        'progress': [500, 0],
      }));

      final task = DownloadTask(
        id: 't_valid',
        fileName: 'task.iso',
        url: 'https://example.com/task.iso',
        fileSize: 10000,
        downloadedBytes: 500,
        category: 'OS',
        status: DownloadStatus.paused,
        savePath: tempDir.path,
        localFilePath: taskFile.path,
        tempFilePath: taskFile.path,
        threadCount: 2,
        chunks: const [0.05, 0.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final result = await orchestrator.validateResumeState(task);

      expect(result.downloadedBytes, equals(500));
      expect(result.chunks, equals(const [0.1, 0.0]));
      expect(await stateFile.exists(), isTrue);
    });
  });
}
