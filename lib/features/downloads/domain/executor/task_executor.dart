import 'dart:async';
import '../commands/download_commands.dart';
import '../events/download_events.dart';
import '../ports/task_engine_port.dart';
import '../ports/task_snapshot_store.dart';
import '../state_machine/domain_state_machine.dart';
import 'task_mailbox.dart';

/// Single-flight, actor-pattern centralized executor for download commands.
///
/// Features:
/// 1. Per-task serialized actor mailboxes ensuring commands for the same task
///    NEVER execute concurrently.
/// 2. ONE lock total across the download core: [_mailboxEnqueueLock].
/// 3. Table-driven [DomainStateMachine] integration with [TransitionAuditLog].
/// 4. Global command routing.
class TaskExecutor {
  final TaskEnginePort enginePort;
  final TaskSnapshotStore? snapshotStore;
  final TransitionAuditLog auditLog;

  final Map<String, TaskMailbox> _mailboxes = {};
  final Map<String, DomainStateMachine> _stateMachines = {};
  final Set<String> _tombstones = {};
  final StreamController<DownloadEvent> _eventController =
      StreamController<DownloadEvent>.broadcast();

  // The single enqueue lock for mailbox resolution and dispatch.
  Completer<void>? _mailboxEnqueueCompleter;

  TaskExecutor({
    required this.enginePort,
    this.snapshotStore,
    TransitionAuditLog? auditLog,
  }) : auditLog = auditLog ?? TransitionAuditLog();

  Stream<DownloadEvent> get events => _eventController.stream;

  bool isTombstoned(String taskId) => _tombstones.contains(taskId);

  DomainStateMachine stateMachineFor(
    String taskId, {
    DomainDownloadState initialState = DomainDownloadState.idle,
  }) {
    return _stateMachines.putIfAbsent(
      taskId,
      () => DomainStateMachine(
        taskId: taskId,
        initialState: initialState,
        auditLog: auditLog,
        onTransitionHook: (id, from, to, cmd) async {
          if (_tombstones.contains(id)) return;
          if (snapshotStore != null) {
            await snapshotStore!.onTaskStateChanged(
              id,
              from,
              to,
              cmd,
            );
          }
        },
      ),
    );
  }

  /// Single lock acquisition for mailbox enqueueing.
  Future<T> _withEnqueueLock<T>(Future<T> Function() block) async {
    while (_mailboxEnqueueCompleter != null) {
      await _mailboxEnqueueCompleter!.future;
    }
    final completer = Completer<void>();
    _mailboxEnqueueCompleter = completer;
    try {
      return await block();
    } finally {
      _mailboxEnqueueCompleter = null;
      completer.complete();
    }
  }

  /// Dispatches a command into the subsystem.
  ///
  /// Task commands are routed to their per-task mailbox (single-flight).
  /// Global commands are routed to appropriate system engines or fan-out handlers.
  Future<void> dispatch(DownloadCommand command) async {
    switch (command) {
      case final TaskCommand taskCmd:
        if (_tombstones.contains(taskCmd.id) && taskCmd is! DeleteTask) {
          return;
        }
        final mailbox = await _withEnqueueLock(() async {
          return _mailboxes.putIfAbsent(
            taskCmd.id,
            () => TaskMailbox(
              taskId: taskCmd.id,
              handler: (cmd, gen) => _executeTaskCommand(taskCmd.id, cmd, gen),
            ),
          );
        });
        return mailbox.enqueue(taskCmd);

      case QueuePump _:
        await enginePort.pumpQueue();

      case final NetworkChanged netCmd:
        await enginePort.handleNetworkChanged(
          isConnected: netCmd.isConnected,
          isWifi: netCmd.isWifi,
        );

      case final AppLifecycleChanged lifeCmd:
        await enginePort.handleAppLifecycleChanged(lifeCmd.state);

      case ReorderQueue _:
        // Handled via queue manager / engine port
        break;
    }
  }

  /// Core task command handler executed sequentially within a task's mailbox.
  Future<void> _executeTaskCommand(
      String taskId, DownloadCommand command, int generation) async {
    if (_tombstones.contains(taskId) && command is! DeleteTask) {
      return;
    }
    final sm = stateMachineFor(taskId);

    switch (command) {
      case final StartTask startCmd:
        if (sm.currentState == DomainDownloadState.downloading ||
            sm.currentState == DomainDownloadState.starting) {
          // Already running
          return;
        }
        sm.transition(
          DomainDownloadState.starting,
          command: startCmd,
          caller: 'TaskExecutor',
          engine: 'TaskEnginePort',
        );
        emitEvent(TaskStarted(taskId: taskId));
        try {
          await enginePort.startEngineTask(
            taskId,
            ignoreQueueLimit: startCmd.ignoreQueueLimit,
          );
        } catch (e) {
          sm.transition(
            DomainDownloadState.failed,
            command: startCmd,
            reason: e.toString(),
            caller: 'TaskExecutor',
            engine: 'TaskEnginePort',
          );
          emitEvent(
            TaskFailed(
              taskId: taskId,
              errorCode: DomainErrorCode.unknown,
              message: e.toString(),
            ),
          );
        }

      case final PauseTask pauseCmd:
        if (sm.currentState == DomainDownloadState.paused) {
          return;
        }
        final prevState = sm.currentState;
        sm.transition(
          DomainDownloadState.paused,
          command: pauseCmd,
          reason: pauseCmd.reason,
          caller: 'TaskExecutor',
          engine: 'TaskEnginePort',
        );
        try {
          await enginePort.pauseEngineTask(
            taskId,
            reason: pauseCmd.reason,
            userInitiated: pauseCmd.userInitiated,
          );
          emitEvent(
            TaskPausedConfirmed(
              taskId: taskId,
              reason: pauseCmd.reason,
              userInitiated: pauseCmd.userInitiated,
            ),
          );
        } catch (e) {
          sm.transition(
            prevState,
            command: pauseCmd,
            reason: 'Rollback on pause error: $e',
            caller: 'TaskExecutor',
            engine: 'TaskEnginePort',
          );
          rethrow;
        }

      case final ResumeTask resumeCmd:
        if (sm.currentState == DomainDownloadState.downloading ||
            sm.currentState == DomainDownloadState.starting) {
          return;
        }
        sm.transition(
          DomainDownloadState.queued,
          command: resumeCmd,
          caller: 'TaskExecutor',
          engine: 'TaskEnginePort',
        );
        emitEvent(TaskEnqueued(taskId: taskId));
        await enginePort.pumpQueue();

      case final CancelTask cancelCmd:
        if (sm.currentState == DomainDownloadState.failed ||
            sm.currentState == DomainDownloadState.idle ||
            sm.currentState == DomainDownloadState.completed) {
          return;
        }
        await enginePort.cancelEngineTask(
          taskId,
          deleteFiles: cancelCmd.deleteFiles,
        );
        sm.transition(
          DomainDownloadState.failed,
          command: cancelCmd,
          reason: 'Transfer cancelled.',
          caller: 'TaskExecutor',
          engine: 'TaskEnginePort',
        );
        emitEvent(
          TaskFailed(
            taskId: taskId,
            errorCode: DomainErrorCode.cancelled,
            message: 'Transfer cancelled.',
          ),
        );

      case final DeleteTask deleteCmd:
        await enginePort.deleteEngineTask(
          taskId,
          deleteFiles: deleteCmd.deleteFiles,
        );
        if (snapshotStore != null) {
          await snapshotStore!.deleteTaskSnapshot(taskId);
        }
        sm.transition(
          DomainDownloadState.idle,
          command: deleteCmd,
          caller: 'TaskExecutor',
          engine: 'TaskEnginePort',
        );
        emitEvent(
          TaskDeleted(
            taskId: taskId,
            filesDeleted: deleteCmd.deleteFiles,
          ),
        );
        _tombstones.add(taskId);
        await _withEnqueueLock(() async {
          _mailboxes[taskId]?.markTombstone();
          _mailboxes.remove(taskId);
          _stateMachines.remove(taskId);
        });

      case final RetryTask retryCmd:
        sm.transition(
          DomainDownloadState.queued,
          command: retryCmd,
          caller: 'TaskExecutor',
          engine: 'TaskEnginePort',
        );
        emitEvent(TaskEnqueued(taskId: taskId));
        await enginePort.retryEngineTask(taskId);

      case final ScheduleFired schedCmd:
        sm.transition(
          DomainDownloadState.queued,
          command: schedCmd,
          caller: 'TaskExecutor',
          engine: 'ScheduleManager',
        );
        emitEvent(TaskEnqueued(taskId: taskId));
        await enginePort.pumpQueue();

      case final TorrentStatsTick tickCmd:
        await enginePort.handleTorrentStats(taskId, tickCmd.stats);

      case UpdateTaskUrl _:
        // Engine URL update handler
        break;

      case SetTaskPriority _:
        // Priority update handler
        break;

      default:
        break;
    }
  }

  void emitEvent(DownloadEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  void dispose() {
    _eventController.close();
    for (final mailbox in _mailboxes.values) {
      mailbox.close();
    }
    _mailboxes.clear();
    for (final sm in _stateMachines.values) {
      sm.dispose();
    }
    _stateMachines.clear();
  }
}
