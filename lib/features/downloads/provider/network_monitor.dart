import 'dart:async';

// ignore_for_file: prefer_initializing_formals

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';

import '../../../core/services/torrent_service.dart';
import '../models/download_task.dart';

/// Watches device connectivity and pauses/resumes downloads accordingly.
///
/// Extracted from [DownloadProvider] (Refactor A). The monitor owns all
/// connectivity state (current results, wifi-only bookkeeping, the set of
/// tasks it auto-paused) and calls back into the provider through the
/// constructor callbacks for task mutations and queue pumping.
class NetworkMonitor {
  NetworkMonitor({
    required List<DownloadTask> Function() tasks,
    required Map<String, int> Function() torrentIds,
    required Map<String, CancelToken> Function() cancelTokens,
    required bool Function() wifiOnly,
    required Future<void> Function(DownloadTask updated) setTask,
    required void Function() pumpQueue,
  })  : _tasks = tasks,
        _torrentIds = torrentIds,
        _cancelTokens = cancelTokens,
        _wifiOnly = wifiOnly,
        _setTask = setTask,
        _pumpQueue = pumpQueue;

  final List<DownloadTask> Function() _tasks;
  final Map<String, int> Function() _torrentIds;
  final Map<String, CancelToken> Function() _cancelTokens;
  final bool Function() _wifiOnly;
  final Future<void> Function(DownloadTask updated) _setTask;
  final void Function() _pumpQueue;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  List<ConnectivityResult> _currentConnectivity = [];
  bool _hasResolvedInitialConnectivity = false;
  bool _checkingNetwork = false;
  bool _networkRecheckPending = false;
  final Set<String> _tasksPausedDueToDisconnect = {};
  final Set<String> _tasksPausedDueToWifiOnly = {};

  /// The most recent connectivity results reported by the platform.
  List<ConnectivityResult> get currentConnectivity => _currentConnectivity;

  /// Whether the device is currently on Wi-Fi or Ethernet.
  bool get hasWifiOrEthernet =>
      _currentConnectivity.contains(ConnectivityResult.wifi) ||
      _currentConnectivity.contains(ConnectivityResult.ethernet);

  void markWifiWaiting(String taskId) {
    _tasksPausedDueToWifiOnly.add(taskId);
  }

  void init() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      _currentConnectivity = results;
      _hasResolvedInitialConnectivity = true;
      checkNetworkConnectivity();
    });
    Connectivity().checkConnectivity().then((results) {
      if (!_hasResolvedInitialConnectivity) {
        _currentConnectivity = results;
        _hasResolvedInitialConnectivity = true;
        checkNetworkConnectivity();
      }
    });
  }

  /// Resolves connectivity synchronously on first load so wifi-only checks
  /// run against real data before any downloads are pumped.
  Future<void> ensureInitialConnectivity() async {
    if (!_hasResolvedInitialConnectivity) {
      _currentConnectivity = await Connectivity().checkConnectivity();
      _hasResolvedInitialConnectivity = true;
    }
  }

  Future<void> checkNetworkConnectivity({bool skipPump = false}) async {
    if (_checkingNetwork) {
      _networkRecheckPending = true;
      return;
    }
    _checkingNetwork = true;
    try {
      final hasNoNetwork =
          _currentConnectivity.contains(ConnectivityResult.none) ||
              _currentConnectivity.isEmpty;

      if (hasNoNetwork) {
        await _pauseForNetworkDisconnect();
        return;
      } else {
        await _resumeFromNetworkDisconnect(skipPump: skipPump);
      }

      if (!_wifiOnly()) {
        await _resumeWaitingForWifi(skipPump: skipPump);
        return;
      }

      final hasWifi = _currentConnectivity.contains(ConnectivityResult.wifi) ||
          _currentConnectivity.contains(ConnectivityResult.ethernet);

      if (!hasWifi) {
        await _pauseForWifiOnly();
      } else {
        await _resumeWaitingForWifi(skipPump: skipPump);
      }
    } finally {
      _checkingNetwork = false;
      if (_networkRecheckPending) {
        _networkRecheckPending = false;
        // FIX(C-H4): Break potential synchronous recursion from rapid
        // platform connectivity events by deferring to a microtask.
        unawaited(Future.microtask(
            () => checkNetworkConnectivity(skipPump: skipPump)));
      }
    }
  }

  Future<void> _pauseForNetworkDisconnect() async {
    final active = _tasks().where(
      (task) =>
          task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued,
    );
    for (final task in active.toList()) {
      _tasksPausedDueToDisconnect.add(task.id);
      if (task.status == DownloadStatus.downloading) {
        final torrentId = _torrentIds()[task.id];
        if (torrentId != null) {
          TorrentService.pauseTorrent(torrentId);
        }
        // No cancellation gate needed - cancel token removal handles resumes.
        _cancelTokens()[task.id]?.cancel('network_disconnect_pause');
        _cancelTokens().remove(task.id);
      }
      await _setTask(
        task.copyWith(
          status: DownloadStatus.paused,
          speed: 0,
          clearEta: true,
          errorMessage: DownloadStatusMessages.waitingNetwork,
        ),
      );
    }
  }

  Future<void> _resumeFromNetworkDisconnect({bool skipPump = false}) async {
    if (_tasksPausedDueToDisconnect.isEmpty) return;

    final waiting = _tasks().where(
      (task) =>
          _tasksPausedDueToDisconnect.contains(task.id) &&
          task.status == DownloadStatus.paused,
    );
    for (final task in waiting.toList()) {
      if (task.pausedByUser) {
        _tasksPausedDueToDisconnect.remove(task.id);
        continue;
      }
      await _setTask(
        task.copyWith(
          status: DownloadStatus.queued,
          clearError: true,
          clearEta: true,
        ),
      );
    }
    _tasksPausedDueToDisconnect.clear();
    if (!skipPump) _pumpQueue();
  }

  Future<void> _pauseForWifiOnly() async {
    final active = _tasks().where(
      (task) =>
          task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued,
    );
    for (final task in active.toList()) {
      _tasksPausedDueToWifiOnly.add(task.id);
      if (task.status == DownloadStatus.downloading) {
        final torrentId = _torrentIds()[task.id];
        if (torrentId != null) {
          TorrentService.pauseTorrent(torrentId);
        }
        // No cancellation gate needed - cancel token removal handles resumes.
        _cancelTokens()[task.id]?.cancel('wifi_only_pause');
        _cancelTokens().remove(task.id);
      }
      await _setTask(
        task.copyWith(
          status: DownloadStatus.paused,
          speed: 0,
          clearEta: true,
          errorMessage: DownloadStatusMessages.waitingWifi,
        ),
      );
    }
  }

  Future<void> _resumeWaitingForWifi({bool skipPump = false}) async {
    final waiting = _tasks().where(
      (task) =>
          (_tasksPausedDueToWifiOnly.contains(task.id) ||
              task.errorMessage == DownloadStatusMessages.waitingWifi) &&
          task.status == DownloadStatus.paused,
    );
    for (final task in waiting.toList()) {
      if (task.pausedByUser) {
        _tasksPausedDueToWifiOnly.remove(task.id);
        continue;
      }
      await _setTask(
        task.copyWith(
          status: DownloadStatus.queued,
          clearError: true,
          clearEta: true,
        ),
      );
    }
    _tasksPausedDueToWifiOnly.clear();
    if (!skipPump) _pumpQueue();
  }

  void dispose() {
    _connectivitySubscription?.cancel();
    _tasksPausedDueToDisconnect.clear();
    _tasksPausedDueToWifiOnly.clear();
  }
}
