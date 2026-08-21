// FIX-P1-01: Extracted task lifecycle orchestration from DownloadProvider
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'task_state_service.dart';

/// Service for coordinating task lifecycle transitions safely.
class TaskLifecycleService {
  // ignore: unused_field
  final TaskStateService _stateService;
  final Map<String, Future<void>> _inFlightOps = {};

  TaskLifecycleService(this._stateService);

  bool isOperationPending(String taskId) => _inFlightOps.containsKey(taskId);

  Future<void> runGuardedOperation(
    String id,
    String opName,
    Future<void> Function() body,
  ) async {
    if (id.isEmpty) return;

    if (_inFlightOps.containsKey(id)) {
      debugPrint(
          '[TaskLifecycleService] $opName for $id already in flight, joining.');
      return _inFlightOps[id];
    }

    final completer = Completer<void>();
    _inFlightOps[id] = completer.future;

    try {
      await body();
      completer.complete();
    } catch (e, st) {
      debugPrint('[TaskLifecycleService] $opName failed for $id: $e\n$st');
      completer.completeError(e, st);
      rethrow;
    } finally {
      _inFlightOps.remove(id);
    }
  }

  void cancelAllPendingOperations() {
    _inFlightOps.clear();
  }

  void dispose() {
    cancelAllPendingOperations();
  }
}
