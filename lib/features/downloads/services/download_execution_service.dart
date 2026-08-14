import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Contract for the execution environment hosting [DownloadExecutionService].
abstract class DownloadExecutionHost {
  Future<void> executeDownload(String taskId, {bool isAutoRetry = false});
  Future<void> pauseDownload(String taskId);
  Future<void> resumeDownload(String taskId);
  Future<void> retryDownload(String taskId);
  Future<void> cancelDownload(String taskId);
}

/// Service responsible for managing the execution lifecycle of downloads
/// (start, pause, resume, retry, cancel) and tracking running tokens/futures.
class DownloadExecutionService {
  final DownloadExecutionHost _host;
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, Future<void>> _activeFutures = {};
  final Map<String, bool> _operationsInProgress = {};

  DownloadExecutionService({required DownloadExecutionHost host})
      : _host = host;

  Map<String, CancelToken> get cancelTokens => _cancelTokens;
  Map<String, Future<void>> get activeFutures => _activeFutures;

  CancelToken getOrCreateCancelToken(String taskId) {
    var token = _cancelTokens[taskId];
    if (token == null || token.isCancelled) {
      token = CancelToken();
      _cancelTokens[taskId] = token;
    }
    return token;
  }

  void registerActiveFuture(String taskId, Future<void> future) {
    _activeFutures[taskId] = future;
  }

  void removeActiveFuture(String taskId) {
    _activeFutures.remove(taskId);
  }

  void cancelToken(String taskId, [String? reason]) {
    final token = _cancelTokens[taskId];
    if (token != null && !token.isCancelled) {
      token.cancel(reason ?? 'cancelled');
    }
    _cancelTokens.remove(taskId);
  }

  bool isOperationInProgress(String taskId) =>
      _operationsInProgress[taskId] == true;

  Future<void> runGuarded(
      String taskId, String opName, Future<void> Function() action) async {
    if (_operationsInProgress[taskId] == true) return;
    _operationsInProgress[taskId] = true;
    try {
      await action();
    } catch (e) {
      debugPrint('[DownloadExecutionService] $opName failed for $taskId: $e');
      rethrow;
    } finally {
      _operationsInProgress[taskId] = false;
    }
  }

  Future<void> startTask(String taskId) async {
    await _host.executeDownload(taskId);
  }

  Future<void> pauseTask(String taskId) async {
    await _host.pauseDownload(taskId);
  }

  Future<void> resumeTask(String taskId) async {
    await _host.resumeDownload(taskId);
  }

  Future<void> retryTask(String taskId) async {
    await _host.retryDownload(taskId);
  }

  Future<void> cancelTask(String taskId) async {
    await _host.cancelDownload(taskId);
  }
}
