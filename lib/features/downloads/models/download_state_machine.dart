import 'dart:async';
import 'package:logging/logging.dart';
import '../domain/models/domain_download_state.dart';
import '../domain/state_machine/invalid_transition_error.dart';
import '../domain/state_machine/transition_audit_log.dart';
import 'download_task.dart';

export '../domain/models/domain_download_state.dart';
export '../domain/state_machine/invalid_transition_error.dart';
export '../domain/state_machine/transition_audit_log.dart';

/// Explicit download state representations covering all lifecycle stages.
typedef DownloadState = DomainDownloadState;

/// Transition event containing previous state, target state, and optional reason.
class DownloadStateTransition {
  final String taskId;
  final DownloadState from;
  final DownloadState to;
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

/// State machine governing download lifecycle state transitions and validation.
/// Under ARCH-1: Table-driven transition map — the ONLY component permitted to produce
/// new DownloadTask state. Invalid transition throws [InvalidTransitionError] — never
/// silently no-ops, never silently succeeds. Every transition appends to [TransitionAuditLog].
class DownloadStateMachine {
  static final _log = Logger('DownloadStateMachine');

  final String taskId;
  DownloadState _currentState;
  final TransitionAuditLog _auditLog;

  final StreamController<DownloadStateTransition> _transitionController =
      StreamController<DownloadStateTransition>.broadcast();

  DownloadStateMachine({
    required this.taskId,
    DownloadState initialState = DownloadState.idle,
    TransitionAuditLog? auditLog,
  })  : _currentState = initialState,
        _auditLog = auditLog ?? TransitionAuditLog();

  DownloadState get currentState => _currentState;
  Stream<DownloadStateTransition> get transitions =>
      _transitionController.stream;

  /// Allowed transitions matrix
  static const Map<DownloadState, Set<DownloadState>> _allowedTransitions = {
    DownloadState.idle: {
      DownloadState.queued,
      DownloadState.starting,
      DownloadState.downloading,
      DownloadState.failed,
    },
    DownloadState.queued: {
      DownloadState.starting,
      DownloadState.downloading,
      DownloadState.paused,
      DownloadState.failed,
      DownloadState.idle,
    },
    DownloadState.starting: {
      DownloadState.downloading,
      DownloadState.merging,
      DownloadState.paused,
      DownloadState.failed,
      DownloadState.retrying,
    },
    DownloadState.downloading: {
      DownloadState.paused,
      DownloadState.merging,
      DownloadState.completing,
      DownloadState.completed,
      DownloadState.failed,
      DownloadState.retrying,
    },
    DownloadState.paused: {
      DownloadState.queued,
      DownloadState.starting,
      DownloadState.downloading,
      DownloadState.failed,
      DownloadState.idle,
    },
    DownloadState.merging: {
      DownloadState.completing,
      DownloadState.completed,
      DownloadState.failed,
      DownloadState.paused,
      DownloadState.retrying,
    },
    DownloadState.completing: {
      DownloadState.completed,
      DownloadState.failed,
    },
    DownloadState.completed: {
      DownloadState.queued, // re-download / seed
      DownloadState.downloading,
      DownloadState.idle,
      DownloadState.paused, // required for pausing seeding torrents
    },
    DownloadState.failed: {
      DownloadState.queued,
      DownloadState.starting,
      DownloadState.retrying,
      DownloadState.idle,
    },
    DownloadState.retrying: {
      DownloadState.starting,
      DownloadState.downloading,
      DownloadState.paused,
      DownloadState.failed,
    },
  };

  /// Checks if a transition from [from] to [to] is legal.
  static bool canTransition(DownloadState from, DownloadState to) {
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

  /// Attempts to transition the state machine to [targetState].
  /// Throws [InvalidTransitionError] if transition is illegal.
  bool transition(
    DownloadState targetState, {
    String? reason,
    Object? command,
    String? caller,
    String? engine,
  }) {
    if (_currentState == targetState) return true;

    if (!canTransition(_currentState, targetState)) {
      _log.warning(
        'Illegal state transition rejected for task $taskId: '
        '$_currentState -> $targetState (reason: $reason)',
      );
      throw InvalidTransitionError(
        taskId: taskId,
        fromState: _currentState,
        command: command ?? targetState,
        reason: reason,
      );
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
      command: command ?? targetState,
      caller: caller,
      engine: engine,
    );

    if (!_transitionController.isClosed) {
      _transitionController.add(event);
    }

    return true;
  }

  /// Helper to convert legacy [DownloadStatus] to [DownloadState].
  static DownloadState fromStatus(DownloadStatus status) {
    return switch (status) {
      DownloadStatus.queued => DownloadState.queued,
      DownloadStatus.downloading => DownloadState.downloading,
      DownloadStatus.paused => DownloadState.paused,
      DownloadStatus.completed => DownloadState.completed,
      DownloadStatus.failed => DownloadState.failed,
      DownloadStatus.merging => DownloadState.merging,
    };
  }

  /// Helper to map [DownloadState] back to legacy [DownloadStatus].
  static DownloadStatus toStatus(DownloadState state) {
    return switch (state) {
      DownloadState.idle || DownloadState.queued => DownloadStatus.queued,
      DownloadState.starting ||
      DownloadState.downloading ||
      DownloadState.retrying =>
        DownloadStatus.downloading,
      DownloadState.paused => DownloadStatus.paused,
      DownloadState.merging => DownloadStatus.merging,
      DownloadState.completing ||
      DownloadState.completed =>
        DownloadStatus.completed,
      DownloadState.failed => DownloadStatus.failed,
    };
  }

  /// Validates and returns a consistent [CycleState] corresponding to [status].
  static CycleState validateConsistency(DownloadStatus status, CycleState? cycleState) {
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

  void dispose() {
    _transitionController.close();
  }
}
