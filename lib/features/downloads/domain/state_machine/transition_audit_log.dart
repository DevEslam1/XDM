import 'dart:async';
import '../models/domain_download_state.dart';

/// An immutable record of an executed state transition in the download subsystem.
class TransitionAuditLogEntry {
  final String taskId;
  final DomainDownloadState from;
  final DomainDownloadState to;
  final Object command;
  final String? caller;
  final String? engine;
  final DateTime timestamp;

  TransitionAuditLogEntry({
    required this.taskId,
    required this.from,
    required this.to,
    required this.command,
    this.caller,
    this.engine,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() =>
      'TransitionAuditLogEntry(taskId: $taskId, $from -> $to, command: $command, caller: $caller, engine: $engine, at: $timestamp)';
}

/// In-memory audit log holding all transitions and broadcasting them via a stream.
class TransitionAuditLog {
  static final TransitionAuditLog _instance = TransitionAuditLog._internal();
  factory TransitionAuditLog() => _instance;
  TransitionAuditLog._internal();

  final List<TransitionAuditLogEntry> _entries = [];
  final StreamController<TransitionAuditLogEntry> _controller =
      StreamController<TransitionAuditLogEntry>.broadcast();

  List<TransitionAuditLogEntry> get entries => List.unmodifiable(_entries);
  Stream<TransitionAuditLogEntry> get stream => _controller.stream;

  void record(TransitionAuditLogEntry entry) {
    _entries.add(entry);
    if (!_controller.isClosed) {
      _controller.add(entry);
    }
  }

  void recordTransition({
    required String taskId,
    required DomainDownloadState from,
    required DomainDownloadState to,
    required Object command,
    String? caller,
    String? engine,
    DateTime? timestamp,
  }) {
    record(
      TransitionAuditLogEntry(
        taskId: taskId,
        from: from,
        to: to,
        command: command,
        caller: caller,
        engine: engine,
        timestamp: timestamp,
      ),
    );
  }

  void clear() {
    _entries.clear();
  }

  void dispose() {
    _controller.close();
  }
}
