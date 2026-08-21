import '../models/domain_download_state.dart';

/// Error thrown when an invalid state transition is attempted on a download task.
/// Under ARCH-1, the state machine NEVER silently no-ops or succeeds on invalid transitions.
class InvalidTransitionError extends Error {
  final String taskId;
  final DomainDownloadState fromState;
  final Object command;
  final String? reason;

  InvalidTransitionError({
    required this.taskId,
    required this.fromState,
    required this.command,
    this.reason,
  });

  @override
  String toString() {
    final buffer = StringBuffer('InvalidTransitionError: ')
      ..write('Task "$taskId" cannot execute "$command" ')
      ..write('from state "$fromState".');
    if (reason != null && reason!.isNotEmpty) {
      buffer.write(' Reason: $reason');
    }
    return buffer.toString();
  }
}
