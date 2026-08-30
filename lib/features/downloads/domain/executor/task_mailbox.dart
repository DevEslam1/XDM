import 'dart:async';
import 'dart:collection';
import '../commands/download_commands.dart';

typedef CommandHandler = Future<void> Function(DownloadCommand command, int generation);

/// Actor mailbox ensuring strict single-flight, serialized execution of commands
/// for an individual task with generation/epoch tracking and tombstone protection.
class TaskMailbox {
  final String taskId;
  final CommandHandler _handler;
  final Queue<({DownloadCommand command, int generation, Completer<void> completer})>
      _queue = Queue();
  bool _isDraining = false;
  bool _isClosed = false;
  bool _isTombstoned = false;
  int _generation = 0;

  TaskMailbox({
    required this.taskId,
    required CommandHandler handler,
  }) : _handler = handler;

  bool get isIdle => _queue.isEmpty && !_isDraining;
  int get pendingCount => _queue.length;
  int get generation => _generation;
  bool get isClosed => _isClosed;
  bool get isTombstoned => _isTombstoned;

  /// Increments the task generation/epoch. Any in-flight operation from a previous
  /// generation will be dropped.
  int nextGeneration() {
    _generation++;
    return _generation;
  }

  /// Validates if an async result's generation is still current and untombstoned.
  bool isGenerationValid(int gen) => gen == _generation && !_isClosed && !_isTombstoned;

  /// Marks this task as tombstoned to reject all future operations and late callbacks.
  void markTombstone() {
    _isTombstoned = true;
    _generation++;
    close();
  }

  /// Enqueues a command into the actor mailbox and returns a Future that completes
  /// when the command has finished executing.
  Future<void> enqueue(DownloadCommand command) {
    if (_isTombstoned || _isClosed) {
      return Future.error(
        StateError('TaskMailbox for task "$taskId" is closed/tombstoned.'),
      );
    }

    final completer = Completer<void>();
    _queue.add((command: command, generation: _generation, completer: completer));

    if (!_isDraining) {
      _drain();
    }

    return completer.future;
  }

  Future<void> _drain() async {
    if (_isDraining) return;
    _isDraining = true;

    try {
      while (_queue.isNotEmpty && !_isClosed && !_isTombstoned) {
        final item = _queue.removeFirst();
        // Drop command if generation advanced while waiting in queue
        if (item.generation < _generation && item.command is! DeleteTask) {
          if (!item.completer.isCompleted) {
            item.completer.complete();
          }
          continue;
        }

        try {
          await _handler(item.command, item.generation);
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
      if (_queue.isNotEmpty && !_isClosed && !_isTombstoned) {
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
