import 'dart:async';
import 'package:dmx/features/downloads/models/download_task.dart';

/// Abstract interface for Task Data Sources (M-ARCH-05).
abstract class ITaskDataSource {
  Future<List<DownloadTask>> getAll();
  Future<DownloadTask?> getById(String id);
  Future<void> save(DownloadTask task);
  Future<void> saveAll(List<DownloadTask> tasks);
  Future<void> delete(String id);
  Future<void> deleteAll(List<String> ids);
  Stream<DownloadTask> watchTask(String id);
}
