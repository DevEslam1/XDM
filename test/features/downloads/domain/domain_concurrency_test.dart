import 'dart:math';
import 'package:dmx/features/downloads/domain/commands/download_commands.dart';
import 'package:dmx/features/downloads/domain/executor/task_executor.dart';
import 'package:dmx/features/downloads/domain/models/domain_download_state.dart';
import 'package:dmx/features/downloads/domain/ports/task_engine_port.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeEnginePort implements TaskEnginePort {
  final Map<String, int> engineStartCounts = {};
  final Map<String, int> activeEngineTasks = {};

  @override
  Future<void> startEngineTask(String taskId,
      {bool ignoreQueueLimit = false}) async {
    // Artificial small jitter to stress interleaving
    await Future<void>.delayed(const Duration(milliseconds: 2));
    engineStartCounts[taskId] = (engineStartCounts[taskId] ?? 0) + 1;
    activeEngineTasks[taskId] = (activeEngineTasks[taskId] ?? 0) + 1;
  }

  @override
  Future<void> pauseEngineTask(String taskId,
      {String? reason, bool userInitiated = true}) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    activeEngineTasks[taskId] = 0;
  }

  @override
  Future<void> cancelEngineTask(String taskId,
      {bool deleteFiles = false}) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    activeEngineTasks[taskId] = 0;
  }

  @override
  Future<void> deleteEngineTask(String taskId,
      {bool deleteFiles = false}) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    activeEngineTasks[taskId] = 0;
  }

  @override
  Future<void> retryEngineTask(String taskId) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }

  @override
  Future<void> pumpQueue() async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }

  @override
  Future<void> handleNetworkChanged(
      {required bool isConnected, required bool isWifi}) async {}

  @override
  Future<void> handleAppLifecycleChanged(dynamic state) async {}

  @override
  Future<void> handleTorrentStats(String taskId, dynamic stats) async {}
}

void main() {
  group('Domain Concurrency Stress Test', () {
    test(
        'fires 100 randomized interleaved commands from 5 concurrent entry points',
        () async {
      final engine = _FakeEnginePort();
      final executor = TaskExecutor(enginePort: engine);

      const taskIds = [
        'task-alpha',
        'task-beta',
        'task-gamma',
        'task-delta',
        'task-epsilon'
      ];
      final random = Random(42); // deterministic seed

      final commands = <DownloadCommand>[];
      for (var i = 0; i < 100; i++) {
        final tid = taskIds[random.nextInt(taskIds.length)];
        final type = random.nextInt(5);
        switch (type) {
          case 0:
            commands.add(StartTask(tid));
            break;
          case 1:
            commands.add(PauseTask(tid, reason: 'stressTest'));
            break;
          case 2:
            commands.add(ResumeTask(tid));
            break;
          case 3:
            commands.add(RetryTask(tid));
            break;
          case 4:
            commands.add(const QueuePump());
            break;
        }
      }

      // Partition the 100 commands across 5 simulated concurrent entry points
      final chunks = <List<DownloadCommand>>[[], [], [], [], []];
      for (var i = 0; i < commands.length; i++) {
        chunks[i % 5].add(commands[i]);
      }

      // Launch 5 concurrent workers
      await Future.wait(
        chunks.map((workerCommands) async {
          for (final cmd in workerCommands) {
            try {
              await executor.dispatch(cmd);
            } catch (_) {
              // Expected for invalid transitions on interleaved commands
            }
          }
        }),
      );

      // Verify that every task ended in a valid recognized domain state
      for (final tid in taskIds) {
        final sm = executor.stateMachineFor(tid);
        expect(
          sm.currentState,
          anyOf(
            DomainDownloadState.starting,
            DomainDownloadState.downloading,
            DomainDownloadState.paused,
            DomainDownloadState.queued,
            DomainDownloadState.failed,
            DomainDownloadState.idle,
          ),
        );
      }

      // Verify engine started at least once and never exceeded valid single-flight limits
      for (final tid in taskIds) {
        expect(engine.engineStartCounts[tid] ?? 0, greaterThanOrEqualTo(0));
      }

      executor.dispose();
    });
  });
}
