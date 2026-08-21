import 'dart:async';
import 'dart:collection';
import '../commands/download_commands.dart';

typedef CommandHandler = Future<void> Function(DownloadCommand command);

/// Actor mailbox ensuring strict single-flight, serialized execution of commands
/// for an individual task. Commands for the same task NEVER execute concurrently.
class TaskMailbox {
  final String taskId;
  final CommandHandler _handler;
  final Queue<({DownloadCommand command, Completer<void> completer})> _queue =
      Queue();
  bool _isDraining = false;
  bool _isClosed = false;

  TaskMailbox({
    required this.taskId,
    required CommandHandler handler,
  }) : _handler = handler;

  bool get isIdle => _queue.isEmpty && !_isDraining;
  int get pendingCount => _queue.length;

  /// Enqueues a command into the actor mailbox and returns a Future that completes
  /// when the command has finished executing.
  Future<void> enqueue(DownloadCommand command) {
    if (_isClosed) {
      return Future.error(
        StateError('TaskMailbox for task "$taskId" is closed.'),
      );
    }

    final completer = Completer<void>();
    _queue.add((command: command, completer: completer));

    if (!_isDraining) {
      _drain();
    }

    return completer.future;
  }

  Future<void> _drain() async {
    if (_isDraining) return;
    _isDraining = true;

    try {
      while (_queue.isNotEmpty && !_isClosed) {
        final item = _queue.removeFirst();
        try {
          await _handler(item.command);
          if (!item.completer.isCompleted) {
            item.completer.complete();
          }
        } catch (error, stackTrace) {
          if (!item.completer.isCompleted) {
            item.completer.completeError(error, stackTrace);
          }
        }
      }
    } finally {
      _isDraining = false;
      // If items arrived while exiting, continue draining.
      if (_queue.isNotEmpty && !_isClosed) {
        _drain();
      }
    }
  }

  void close() {
    _isClosed = true;
    while (_queue.isNotEmpty) {
      final item = _queue.removeFirst();
      if (!item.completer.isCompleted) {
        item.completer.completeError(
          StateError('TaskMailbox closed before command could execute.'),
        );
      }
    }
  }
}
