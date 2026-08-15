import 'dart:async';
import 'package:logging/logging.dart';
import 'download_task.dart';

/// Explicit download state representations covering all lifecycle stages.
enum DownloadState {
  idle,
  queued,
  starting,
  downloading,
  paused,
  merging,
  completing,
  completed,
  failed,
  retrying,
}

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
class DownloadStateMachine {
  static final _log = Logger('DownloadStateMachine');

  final String taskId;
  DownloadState _currentState;

  final StreamController<DownloadStateTransition> _transitionController =
      StreamController<DownloadStateTransition>.broadcast();

  DownloadStateMachine({
    required this.taskId,
    DownloadState initialState = DownloadState.idle,
  }) : _currentState = initialState;

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

  /// Attempts to transition the state machine to [targetState].
  /// Returns `true` if transition was valid and executed, `false` otherwise.
  bool transition(DownloadState targetState, {String? reason}) {
    if (_currentState == targetState) return true;

    if (!canTransition(_currentState, targetState)) {
      _log.warning(
        'Illegal state transition rejected for task $taskId: '
        '$_currentState -> $targetState (reason: $reason)',
      );
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
      DownloadState.completing || DownloadState.completed =>
        DownloadStatus.completed,
      DownloadState.failed => DownloadStatus.failed,
    };
  }

  void dispose() {
    _transitionController.close();
  }
}
