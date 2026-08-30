import 'dart:async';

// ignore_for_file: prefer_initializing_formals

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';

import '../../../core/interfaces/i_connectivity.dart';
import '../../../core/services/torrent_service.dart';
import '../domain/commands/download_commands.dart';
import '../models/download_task.dart';

/// Watches device connectivity and pauses/resumes downloads accordingly.
///
/// Under ARCH-1: pure command emitter emitting [NetworkChanged] when connectivity alters.
class NetworkMonitor implements IConnectivity {
  NetworkMonitor({
    required List<DownloadTask> Function() tasks,
    required Map<String, int> Function() torrentIds,
    required Map<String, CancelToken> Function() cancelTokens,
    Map<String, Future<void>> Function()? activeFutures,
    required bool Function() wifiOnly,
    bool Function()? pauseOnCellular,
    required Future<void> Function(DownloadTask updated) setTask,
    required void Function() pumpQueue,
    Future<void> Function(NetworkChanged event)? onNetworkChanged,
  })  : _tasks = tasks,
        _torrentIds = torrentIds,
        _cancelTokens = cancelTokens,
        _activeFutures = activeFutures ?? (() => <String, Future<void>>{}),
        _wifiOnly = wifiOnly,
        _pauseOnCellular = pauseOnCellular ?? (() => false),
        _setTask = setTask,
        _pumpQueue = pumpQueue,
        _onNetworkChanged = onNetworkChanged;

  final List<DownloadTask> Function() _tasks;
  final Map<String, int> Function() _torrentIds;
  final Map<String, CancelToken> Function() _cancelTokens;
  final Map<String, Future<void>> Function() _activeFutures;
  final bool Function() _wifiOnly;
  final bool Function() _pauseOnCellular;
  // ignore: unused_field
  final Future<void> Function(DownloadTask updated) _setTask;
  final void Function() _pumpQueue;
  final Future<void> Function(NetworkChanged event)? _onNetworkChanged;

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
  ///
  /// BUG10: an empty connectivity list means "unknown", not "disconnected" —
  /// treating unknown as disconnected paused every download on the first
  /// spurious platform callback before any real signal arrived.
  bool get hasNoNetwork =>
      _currentConnectivity.contains(ConnectivityResult.none);

  /// Whether there is any active network connection.
  bool get hasAnyNetworkConnection => !hasNoNetwork;

  /// Alias for hasAnyNetworkConnection.
  @override
  bool get hasConnection => hasAnyNetworkConnection;

  void markWifiWaiting(String taskId) {
    _tasksPausedDueToWifiOnly.add(taskId);
  }

  @visibleForTesting
  void setConnectivityForTesting(List<ConnectivityResult> results) {
    _currentConnectivity = results;
    _hasResolvedInitialConnectivity = true;
  }

  void init() {
    // FIX(C-7): Idempotent — init() was previously never called anywhere, so
    // the whole connectivity-change pipeline (pause on disconnect,
    // wifi-only enforcement, auto-resume on reconnect) was dead at runtime.
    if (_connectivitySubscription != null) return;
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
      LoggingService.logger('NetworkMonitor')
          .warning('Operation failed with fallback', e, st);
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
      // BUG10: unknown connectivity (empty list — no signal resolved yet)
      // must not be read as "disconnected" nor drive wifi-only/cellular
      // pause decisions on the first spurious callback.
      final unknownConnectivity = _currentConnectivity.isEmpty;
      final hasNoNet = !unknownConnectivity &&
          _currentConnectivity.contains(ConnectivityResult.none);

      if (_onNetworkChanged != null) {
        await _onNetworkChanged!(
          NetworkChanged(
            isConnected: !hasNoNet,
            isWifi: hasWifiOrEthernet,
            state: _currentConnectivity,
          ),
        );
      }

      if (hasNoNet) {
        await _pauseForNetworkDisconnect();
        return;
      } else {
        await _resumeFromNetworkDisconnect(skipPump: skipPump);
        if (unknownConnectivity) {
          // Connectivity is still unknown — skip policy decisions.
          return;
        }
      }

      if (!_wifiOnly() && !_pauseOnCellular()) {
        await _resumeWaitingForWifi(skipPump: skipPump);
        return;
      }

      final hasWifi = _currentConnectivity.contains(ConnectivityResult.wifi) ||
          _currentConnectivity.contains(ConnectivityResult.ethernet);

      // wifiOnly pauses on anything that isn't Wi-Fi/Ethernet; pauseOnCellular
      // (without wifiOnly) pauses only when the active link is cellular.
      final mustPause = _wifiOnly() ? !hasWifi : isCellular;

      if (mustPause) {
        await _pauseForWifiOnly();
      } else {
        await _resumeWaitingForWifi(skipPump: skipPump);
      }
    } finally {
      _checkingNetwork = false;
      if (_networkRecheckPending) {
        _networkRecheckPending = false;
        unawaited(Future.microtask(
            () => checkNetworkConnectivity(skipPump: skipPump)));
      }
    }
  }

  Future<void> _pauseForNetworkDisconnect() async {
    final active = _tasks()
        .where(
          (task) =>
              task.status == DownloadStatus.downloading ||
              task.status == DownloadStatus.queued,
        )
        .toList();
    await Future.wait(active.map((task) async {
      _tasksPausedDueToDisconnect.add(task.id);
      if (task.status == DownloadStatus.downloading) {
        final torrentId = _torrentIds()[task.id];
        if (torrentId != null) {
          TorrentService.pauseTorrent(torrentId);
        }
        _cancelTokens()[task.id]?.cancel('network_lost');
        final fut = _activeFutures()[task.id];
        if (fut != null) {
          try {
            await fut.timeout(const Duration(seconds: 5));
          } catch (e, st) {
            LoggingService.logger('NetworkMonitor')
                .warning('Operation failed', e, st);
          }
        }
        _cancelTokens().remove(task.id);
      }
      final sm = DownloadStateMachine(
        taskId: task.id,
        initialState: DownloadStateMachine.fromStatus(task.status),
      );
      sm.transition(
        DomainDownloadState.paused,
        reason: 'networkLost',
        caller: 'NetworkMonitor',
      );
      await _setTask(task.copyWith(
        status: DownloadStatus.paused,
        errorMessage: DownloadStatusMessages.waitingNetwork,
      ));
    }));
  }

  Future<void> _resumeFromNetworkDisconnect({bool skipPump = false}) async {
    if (_tasksPausedDueToDisconnect.isEmpty) return;

    final waiting = _tasks().where(
      (task) =>
          (_tasksPausedDueToDisconnect.contains(task.id) ||
              task.errorMessage == DownloadStatusMessages.waitingNetwork) &&
          task.status == DownloadStatus.paused,
    );
    for (final task in waiting.toList()) {
      if (task.pausedByUser || task.pauseReason == PauseReason.user) {
        _tasksPausedDueToDisconnect.remove(task.id);
        continue;
      }
      final sm = DownloadStateMachine(
        taskId: task.id,
        initialState: DownloadStateMachine.fromStatus(task.status),
      );
      sm.transition(
        DomainDownloadState.queued,
        caller: 'NetworkMonitor',
      );
      await _setTask(task.copyWith(
        status: DownloadStatus.queued,
        errorMessage: null,
      ));
    }
    _tasksPausedDueToDisconnect.clear();
    if (!skipPump) _pumpQueue();
  }

  Future<void> _pauseForWifiOnly() async {
    final active = _tasks()
        .where(
          (task) =>
              task.status == DownloadStatus.downloading ||
              task.status == DownloadStatus.queued,
        )
        .toList();
    await Future.wait(active.map((task) async {
      _tasksPausedDueToWifiOnly.add(task.id);
      if (task.status == DownloadStatus.downloading) {
        final torrentId = _torrentIds()[task.id];
        if (torrentId != null) {
          TorrentService.pauseTorrent(torrentId);
        }
        _cancelTokens()[task.id]?.cancel('wifi_only_pause');
        // BUG3: mirror the disconnect path — await the in-flight engine
        // future (bounded) so late progress ticks settle before the pause
        // is published and the progress guards start dropping them.
        final fut = _activeFutures()[task.id];
        if (fut != null) {
          try {
            await fut.timeout(const Duration(seconds: 5));
          } catch (e, st) {
            LoggingService.logger('NetworkMonitor')
                .warning('Operation failed', e, st);
          }
        }
        _cancelTokens().remove(task.id);
      }
      final sm = DownloadStateMachine(
        taskId: task.id,
        initialState: DownloadStateMachine.fromStatus(task.status),
      );
      sm.transition(
        DomainDownloadState.paused,
        // BUG10: label the pause with its real reason instead of 'networkLost'.
        reason: 'wifi_only_pause',
        caller: 'NetworkMonitor',
      );
      await _setTask(task.copyWith(
        status: DownloadStatus.paused,
        errorMessage: DownloadStatusMessages.waitingWifi,
      ));
    }));
  }

  Future<void> _resumeWaitingForWifi({bool skipPump = false}) async {
    final waiting = _tasks().where(
      (task) =>
          (_tasksPausedDueToWifiOnly.contains(task.id) ||
              task.errorMessage == DownloadStatusMessages.waitingWifi) &&
          task.status == DownloadStatus.paused,
    );
    for (final task in waiting.toList()) {
      if (task.pausedByUser || task.pauseReason == PauseReason.user) {
        _tasksPausedDueToWifiOnly.remove(task.id);
        continue;
      }
      final sm = DownloadStateMachine(
        taskId: task.id,
        initialState: DownloadStateMachine.fromStatus(task.status),
      );
      sm.transition(
        DomainDownloadState.queued,
        caller: 'NetworkMonitor',
      );
      await _setTask(task.copyWith(
        status: DownloadStatus.queued,
        errorMessage: null,
      ));
    }
    _tasksPausedDueToWifiOnly.clear();
    if (!skipPump) _pumpQueue();
  }

  void dispose() {
    _debounceTimer?.cancel();
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }
}
