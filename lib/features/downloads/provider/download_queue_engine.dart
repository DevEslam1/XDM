import 'dart:async';
import '../models/download_task.dart';

/// Handles download queue logic, including concurrency and scheduling.
class DownloadQueueEngine {
  int _maxConcurrent = 3;
  set maxConcurrent(int val) => _maxConcurrent = val;

  void pumpQueue(List<DownloadTask> tasks, Future<void> Function(DownloadTask) onStart) {
    // Logic to start tasks from queue based on concurrency limits
  }
}
