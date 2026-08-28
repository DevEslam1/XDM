import 'dart:async';
import 'package:logging/logging.dart';
import '../../../../core/domain/cycle_state.dart';
import '../../models/download_task.dart' show DownloadStatus;
import '../models/domain_download_state.dart';
import 'invalid_transition_error.dart';
import 'transition_audit_log.dart';

export '../models/domain_download_state.dart';
export 'invalid_transition_error.dart';
export 'transition_audit_log.dart';

final _log = Logger('DomainStateMachine');

/// Explicit download state representations covering all lifecycle stages.
typedef DownloadState = DomainDownloadState;

/// Alias for unified State Machine.
typedef DownloadStateMachine = DomainStateMachine;

/// Transition event containing previous state, target state, and optional reason.
class DownloadStateTransition {
  final String taskId;
  final DomainDownloadState from;
  final DomainDownloadState to;
  final String? reason;
  final DateTime timestamp;

  DownloadStateTransition({
    required this.taskId,
    required this.from,
    required this.to,
    this.reason,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() =>
      'DownloadStateTransition(taskId: $taskId, $from -> $to, reason: $reason)';
}

/// Callback invoked whenever a valid state transition takes place.
typedef OnTransitionHook = FutureOr<void> Function(
  String taskId,
  DomainDownloadState from,
  DomainDownloadState to,
  Object command,
);

/// Pure-Dart table-driven State Machine governing task lifecycle transitions.
/// Under ARCH-1, this is the ONLY component permitted to produce new lifecycle states.
class DomainStateMachine {
  final String taskId;
  DomainDownloadState _currentState;
  final TransitionAuditLog _auditLog;
  final OnTransitionHook? onTransitionHook;

  final StreamController<DomainDownloadState> _stateController =
      StreamController<DomainDownloadState>.broadcast();
  final StreamController<DownloadStateTransition> _transitionController =
      StreamController<DownloadStateTransition>.broadcast();

  DomainStateMachine({
    required this.taskId,
    DomainDownloadState initialState = DomainDownloadState.idle,
    TransitionAuditLog? auditLog,
    this.onTransitionHook,
  })  : _currentState = initialState,
        _auditLog = auditLog ?? TransitionAuditLog();

  DomainDownloadState get currentState => _currentState;
  Stream<DomainDownloadState> get stateStream => _stateController.stream;
  Stream<DownloadStateTransition> get transitions =>
      _transitionController.stream;

  /// Table-driven transition matrix: `Map<FromState, Set<ToState>>`
  static const Map<DomainDownloadState, Set<DomainDownloadState>>
      _allowedTransitions = {
    DomainDownloadState.idle: {
      DomainDownloadState.queued,
      DomainDownloadState.starting,
      DomainDownloadState.downloading,
      DomainDownloadState.failed,
    },
    DomainDownloadState.queued: {
      DomainDownloadState.starting,
      DomainDownloadState.downloading,
      DomainDownloadState.paused,
      DomainDownloadState.failed,
      DomainDownloadState.idle,
    },
    DomainDownloadState.starting: {
      DomainDownloadState.downloading,
      DomainDownloadState.merging,
      DomainDownloadState.paused,
      DomainDownloadState.failed,
      DomainDownloadState.retrying,
    },
    DomainDownloadState.downloading: {
      DomainDownloadState.queued,
      DomainDownloadState.paused,
      DomainDownloadState.merging,
      DomainDownloadState.completing,
      DomainDownloadState.completed,
      DomainDownloadState.failed,
      DomainDownloadState.retrying,
    },
    DomainDownloadState.paused: {
      DomainDownloadState.queued,
      DomainDownloadState.starting,
      DomainDownloadState.downloading,
      DomainDownloadState.failed,
      DomainDownloadState.idle,
    },
    DomainDownloadState.merging: {
      DomainDownloadState.completing,
      DomainDownloadState.completed,
      DomainDownloadState.failed,
      DomainDownloadState.paused,
      DomainDownloadState.retrying,
    },
    DomainDownloadState.completing: {
      DomainDownloadState.completed,
      DomainDownloadState.failed,
    },
    DomainDownloadState.completed: {
      DomainDownloadState.queued,
      DomainDownloadState.downloading,
      DomainDownloadState.idle,
      DomainDownloadState.paused,
    },
    DomainDownloadState.failed: {
      DomainDownloadState.queued,
      DomainDownloadState.starting,
      DomainDownloadState.retrying,
      DomainDownloadState.idle,
    },
    DomainDownloadState.retrying: {
      DomainDownloadState.starting,
      DomainDownloadState.downloading,
      DomainDownloadState.paused,
      DomainDownloadState.failed,
    },
  };

  /// Checks if a transition from [from] to [to] is legal.
  static bool canTransition(DomainDownloadState from, DomainDownloadState to) {
    if (from == to) return true;
    final allowed = _allowedTransitions[from];
    return allowed != null && allowed.contains(to);
  }

  /// Checks if a transition between [DownloadStatus] enum values is legal.
  static bool canTransitionStatus(DownloadStatus from, DownloadStatus to) {
    if (from == to) return true;
    final fromState = fromStatus(from);
    final toState = fromStatus(to);
    return canTransition(fromState, toState);
  }

  /// Helper to convert [DownloadStatus] to [DomainDownloadState].
  static DomainDownloadState fromStatus(DownloadStatus status) {
    return switch (status) {
      DownloadStatus.queued => DomainDownloadState.queued,
      DownloadStatus.downloading => DomainDownloadState.downloading,
      DownloadStatus.paused => DomainDownloadState.paused,
      DownloadStatus.completed => DomainDownloadState.completed,
      DownloadStatus.failed => DomainDownloadState.failed,
      DownloadStatus.merging => DomainDownloadState.merging,
    };
  }

  /// Helper to map [DomainDownloadState] back to [DownloadStatus].
  static DownloadStatus toStatus(DomainDownloadState state) {
    return switch (state) {
      DomainDownloadState.idle ||
      DomainDownloadState.queued =>
        DownloadStatus.queued,
      DomainDownloadState.starting ||
      DomainDownloadState.downloading ||
      DomainDownloadState.retrying =>
        DownloadStatus.downloading,
      DomainDownloadState.paused => DownloadStatus.paused,
      DomainDownloadState.merging => DownloadStatus.merging,
      DomainDownloadState.completing ||
      DomainDownloadState.completed =>
        DownloadStatus.completed,
      DomainDownloadState.failed => DownloadStatus.failed,
    };
  }

  /// Validates and returns a consistent [CycleState] corresponding to [status].
  static CycleState validateConsistency(
      DownloadStatus status, CycleState? cycleState) {
    switch (status) {
      case DownloadStatus.completed:
        if (cycleState != CycleState.seeding) {
          return CycleState.completed;
        }
        return CycleState.seeding;
      case DownloadStatus.paused:
        return CycleState.paused;
      case DownloadStatus.failed:
        return CycleState.failed;
      case DownloadStatus.merging:
        return CycleState.merging;
      case DownloadStatus.queued:
        return CycleState.starting;
      case DownloadStatus.downloading:
        if (cycleState == null ||
            cycleState == CycleState.completed ||
            cycleState == CycleState.paused ||
            cycleState == CycleState.failed) {
          return CycleState.downloading;
        }
        return cycleState;
    }
  }

  /// Transitions the state machine to [targetState].
  ///
  /// In debug mode, throws [InvalidTransitionError] on illegal transition.
  /// In release mode, logs the illegal transition to [TransitionAuditLog] and rejects it.
  bool transition(
    DomainDownloadState targetState, {
    Object? command,
    String? reason,
    String? caller,
    String? engine,
  }) {
    final effectiveCommand = command ?? targetState;

    if (!canTransition(_currentState, targetState)) {
      _log.warning(
        'Illegal state transition rejected for task $taskId: '
        '$_currentState -> $targetState (reason: $reason)',
      );

      _auditLog.recordTransition(
        taskId: taskId,
        from: _currentState,
        to: targetState,
        command: effectiveCommand,
        caller: caller,
        engine: engine,
      );

      bool isDebug = false;
      assert(() {
        isDebug = true;
        return true;
      }());
      if (isDebug) {
        throw InvalidTransitionError(
          taskId: taskId,
          fromState: _currentState,
          command: effectiveCommand,
          reason: reason,
        );
      }
      return false;
    }

    final previous = _currentState;
    _currentState = targetState;

    final event = DownloadStateTransition(
      taskId: taskId,
      from: previous,
      to: targetState,
      reason: reason,
    );

    _auditLog.recordTransition(
      taskId: taskId,
      from: previous,
      to: targetState,
      command: effectiveCommand,
      caller: caller,
      engine: engine,
    );

    if (!_stateController.isClosed) {
      _stateController.add(targetState);
    }
    if (!_transitionController.isClosed) {
      _transitionController.add(event);
    }

    if (onTransitionHook != null) {
      final hookResult =
          onTransitionHook!(taskId, previous, targetState, effectiveCommand);
      if (hookResult is Future) {
        unawaited(hookResult);
      }
    }

    return true;
  }

  void dispose() {
    _stateController.close();
    _transitionController.close();
  }
}
