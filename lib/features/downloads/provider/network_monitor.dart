import 'dart:async';

// ignore_for_file: prefer_initializing_formals

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/logging_service.dart';

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
    Map<String, Future<void>> Function()? activeFutures,
    required bool Function() wifiOnly,
    required Future<void> Function(DownloadTask updated) setTask,
    required void Function() pumpQueue,
  })  : _tasks = tasks,
        _torrentIds = torrentIds,
        _cancelTokens = cancelTokens,
        _activeFutures = activeFutures ?? (() => <String, Future<void>>{}),
        _wifiOnly = wifiOnly,
        _setTask = setTask,
        _pumpQueue = pumpQueue;

  final List<DownloadTask> Function() _tasks;
  final Map<String, int> Function() _torrentIds;
  final Map<String, CancelToken> Function() _cancelTokens;
  final Map<String, Future<void>> Function() _activeFutures;
  final bool Function() _wifiOnly;
  final Future<void> Function(DownloadTask updated) _setTask;
  final void Function() _pumpQueue;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  List<ConnectivityResult> _currentConnectivity = [];
  bool _hasResolvedInitialConnectivity = false;
  bool _checkingNetwork = false;
  bool _networkRecheckPending = false;
  Timer? _debounceTimer;
  static const Duration debounceDuration = Duration(seconds: 2);
  final Set<String> _tasksPausedDueToDisconnect = {};
  final Set<String> _tasksPausedDueToWifiOnly = {};

  /// The most recent connectivity results reported by the platform.
  List<ConnectivityResult> get currentConnectivity => _currentConnectivity;

  bool get hasResolvedInitialConnectivity => _hasResolvedInitialConnectivity;

  /// Whether the device is currently on Wi-Fi or Ethernet.
  bool get hasWifiOrEthernet =>
      _currentConnectivity.contains(ConnectivityResult.wifi) ||
      _currentConnectivity.contains(ConnectivityResult.ethernet);

  /// Whether the device is currently on mobile / cellular connection.
  bool get isCellular =>
      _currentConnectivity.contains(ConnectivityResult.mobile);

  /// Whether there is no network connection available.
  bool get hasNoNetwork =>
      _currentConnectivity.contains(ConnectivityResult.none) ||
      _currentConnectivity.isEmpty;

  /// Whether there is any active network connection.
  bool get hasAnyNetworkConnection => !hasNoNetwork;

  void markWifiWaiting(String taskId) {
    _tasksPausedDueToWifiOnly.add(taskId);
  }

  void init() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      _currentConnectivity = results;
      _hasResolvedInitialConnectivity = true;
      _debounceTimer?.cancel();
      _debounceTimer = Timer(debounceDuration, () {
        checkNetworkConnectivity();
      });
    });
    Connectivity().checkConnectivity().then((results) {
      if (!_hasResolvedInitialConnectivity) {
        _currentConnectivity = results;
        _hasResolvedInitialConnectivity = true;
        checkNetworkConnectivity();
      }
    });
  }

  static Future<bool> isNetworkReachable({
    Dio? dioClient,
  }) async {
    try {
      final dio = dioClient ?? Dio();
      dio.options.connectTimeout = const Duration(seconds: 3);
      dio.options.receiveTimeout = const Duration(seconds: 3);
      final res = await dio
          .get<void>('http://connectivitycheck.gstatic.com/generate_204');
      return res.statusCode == 204 ||
          (res.statusCode != null &&
              res.statusCode! >= 200 &&
              res.statusCode! < 300);
    } catch (e, st) {
      LoggingService.logger('NetworkMonitor').warning('Operation failed with fallback', e, st);
      return false;
    }
  }

  /// N-01: Probes generate_204 endpoint to ensure network is truly online without captive portal loops.
  static Future<bool> verifyConnectivityProbe({Dio? dioClient}) =>
      isNetworkReachable(dioClient: dioClient);

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
        // Cancel token and await active future so old engine completes before returning
        _cancelTokens()[task.id]?.cancel('network_disconnect_pause');
        final fut = _activeFutures()[task.id];
        if (fut != null) {
          try {
            await fut.timeout(const Duration(seconds: 5));
          } catch (e, st) {
      LoggingService.logger('NetworkMonitor').warning('Operation failed', e, st);
    }
        }
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
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _connectivitySubscription?.cancel();
    _tasksPausedDueToDisconnect.clear();
    _tasksPausedDueToWifiOnly.clear();
  }
}
