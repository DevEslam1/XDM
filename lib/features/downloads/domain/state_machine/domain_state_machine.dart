import 'dart:async';
import '../models/domain_download_state.dart';
import 'invalid_transition_error.dart';
import 'transition_audit_log.dart';

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

  DomainStateMachine({
    required this.taskId,
    DomainDownloadState initialState = DomainDownloadState.idle,
    TransitionAuditLog? auditLog,
    this.onTransitionHook,
  })  : _currentState = initialState,
        _auditLog = auditLog ?? TransitionAuditLog();

  DomainDownloadState get currentState => _currentState;
  Stream<DomainDownloadState> get stateStream => _stateController.stream;

  /// Table-driven transition matrix: `Map<FromState, Set<ToState>>`
  static const Map<DomainDownloadState, Set<DomainDownloadState>> _allowedTransitions = {
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

  /// Transitions the state machine to [targetState] for the given [command].
  ///
  /// Throws [InvalidTransitionError] if the transition is illegal.
  /// Never silently no-ops, never silently succeeds.
  Future<void> transition(
    DomainDownloadState targetState, {
    required Object command,
    String? reason,
    String? caller,
    String? engine,
  }) async {
    if (!canTransition(_currentState, targetState)) {
      throw InvalidTransitionError(
        taskId: taskId,
        fromState: _currentState,
        command: command,
        reason: reason,
      );
    }

    final previous = _currentState;
    _currentState = targetState;

    _auditLog.recordTransition(
      taskId: taskId,
      from: previous,
      to: targetState,
      command: command,
      caller: caller,
      engine: engine,
    );

    if (!_stateController.isClosed) {
      _stateController.add(targetState);
    }

    if (onTransitionHook != null) {
      await onTransitionHook!(taskId, previous, targetState, command);
    }
  }

  void dispose() {
    _stateController.close();
  }
}
