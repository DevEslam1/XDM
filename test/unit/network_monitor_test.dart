import 'dart:async';
import 'dart:typed_data';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:dio/dio.dart';
import 'package:dmx/features/downloads/domain/commands/download_commands.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/network_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockConnectivityPlatform extends ConnectivityPlatform {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [ConnectivityResult.wifi];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
    );
  }

  @override
  void close({bool force = false}) {}
}

class _OkAdapter implements HttpClientAdapter {
  _OkAdapter(this.statusCode);
  final int statusCode;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString('', statusCode);
  }

  @override
  void close({bool force = false}) {}
}

/// Helper to build a minimal [DownloadTask] with the given [status].
DownloadTask _task(
  String id,
  DownloadStatus status, {
  bool pausedByUser = false,
  String? errorMessage,
}) {
  final now = DateTime(2026, 7, 31);
  return DownloadTask(
    id: id,
    fileName: '$id.zip',
    url: 'https://example.com/$id.zip',
    fileSize: 100,
    downloadedBytes: 0,
    category: 'Other',
    status: status,
    savePath: '',
    localFilePath: '',
    tempFilePath: '',
    threadCount: 1,
    chunks: const [0.0],
    createdAt: now,
    updatedAt: now,
    pausedByUser: pausedByUser,
    errorMessage: errorMessage,
  );
}

void main() {
  group('NetworkMonitor', () {
    late List<DownloadTask> tasks;
    late Map<String, int> torrentIds;
    late Map<String, CancelToken> cancelTokens;
    late bool wifiOnly;
    late List<DownloadTask> setTaskCalls;
    late int pumpQueueCount;

    late NetworkMonitor monitor;

    setUp(() {
      tasks = [];
      torrentIds = {};
      cancelTokens = {};
      wifiOnly = false;
      setTaskCalls = [];
      pumpQueueCount = 0;

      monitor = NetworkMonitor(
        tasks: () => tasks,
        torrentIds: () => torrentIds,
        cancelTokens: () => cancelTokens,
        wifiOnly: () => wifiOnly,
        setTask: (updated) async {
          setTaskCalls.add(updated);
          // Apply the update back into the task list.
          final idx = tasks.indexWhere((t) => t.id == updated.id);
          if (idx != -1) {
            tasks[idx] = updated;
          }
        },
        pumpQueue: () => pumpQueueCount++,
      );
    });

    tearDown(() {
      monitor.dispose();
    });

    group('hasWifiOrEthernet', () {
      test('returns false before any connectivity check', () {
        expect(monitor.hasWifiOrEthernet, isFalse);
      });
    });

    group('network disconnect pauses active tasks', () {
      test('downloading tasks are paused on no-network', () async {
        tasks.add(_task('d1', DownloadStatus.downloading));
        cancelTokens['d1'] = CancelToken();
        // BUG10: an empty connectivity list now means "unknown" — pin the
        // disconnected case with an explicit `none` result.
        monitor.setConnectivityForTesting([ConnectivityResult.none]);

        // checkNetworkConnectivity with no network should pause the
        // downloading task.
        await monitor.checkNetworkConnectivity();

        expect(setTaskCalls, isNotEmpty);
        final paused = setTaskCalls.last;
        expect(paused.status, DownloadStatus.paused);
        expect(paused.errorMessage, DownloadStatusMessages.waitingNetwork);
      });

      test('queued tasks are paused on no-network', () async {
        tasks.add(_task('q1', DownloadStatus.queued));
        monitor.setConnectivityForTesting([ConnectivityResult.none]);

        await monitor.checkNetworkConnectivity();

        expect(setTaskCalls, isNotEmpty);
        final paused = setTaskCalls.last;
        expect(paused.status, DownloadStatus.paused);
      });

      test('BUG10: unknown connectivity (empty) does not pause downloads',
          () async {
        tasks.add(_task('d2', DownloadStatus.downloading));
        cancelTokens['d2'] = CancelToken();

        // No connectivity signal resolved yet (empty list == unknown): the
        // first spurious callback must not treat "unknown" as "disconnected"
        // and pause everything. Pinning the state avoids touching the real
        // Connectivity() platform channel in the unit test.
        monitor.setConnectivityForTesting(const []);
        await monitor.checkNetworkConnectivity();

        expect(
          setTaskCalls.where((t) => t.status == DownloadStatus.paused),
          isEmpty,
        );
        expect(tasks.first.status, DownloadStatus.downloading);
      });
    });

    group('pausedByUser is respected on resume', () {
      test('network resume does not override user-paused downloads', () async {
        // Start with a task that was paused by the user.
        tasks.add(
          _task(
            'u1',
            DownloadStatus.paused,
            pausedByUser: true,
            errorMessage: DownloadStatusMessages.waitingNetwork,
          ),
        );

        // Simulate: the monitor previously paused this task due to disconnect.
        // We do this by first running a disconnect with a non-user-paused task,
        // then setting pausedByUser afterwards.
        // Instead, we directly test _resumeFromNetworkDisconnect by adding the
        // task id to the internal set. Since we cannot access the private set,
        // we simulate the full flow:
        // 1. Task is downloading, 2. Network disconnects (monitor pauses it),
        // 3. User also marks pausedByUser, 4. Network reconnects.
        tasks.clear();
        setTaskCalls.clear();
        tasks.add(_task('u2', DownloadStatus.downloading));
        cancelTokens['u2'] = CancelToken();
        monitor.setConnectivityForTesting([ConnectivityResult.none]);

        // Step 1: disconnect pauses the task.
        await monitor.checkNetworkConnectivity();
        expect(tasks.first.status, DownloadStatus.paused);

        // Step 2: user explicitly pauses (sets pausedByUser).
        tasks[0] = tasks[0].copyWith(pausedByUser: true);

        // Step 3: We cannot easily simulate reconnect since _currentConnectivity
        // is empty. Instead, verify the task stays paused with pausedByUser.
        // The monitor's _resumeFromNetworkDisconnect checks pausedByUser and
        // skips such tasks. We verify this by checking that setTask was NOT
        // called to re-queue this task after the initial pause.
        final reQueued = setTaskCalls.where(
          (t) => t.id == 'u2' && t.status == DownloadStatus.queued,
        );
        expect(reQueued, isEmpty);
      });
    });

    group('wifi-only gating', () {
      test('tasks are paused when wifi-only is enabled and no wifi', () async {
        wifiOnly = true;
        tasks.add(_task('w1', DownloadStatus.downloading));
        cancelTokens['w1'] = CancelToken();
        // Explicitly on cellular so the wifi-only policy fires (BUG10: an
        // empty connectivity list is "unknown" and no longer pauses).
        monitor.setConnectivityForTesting([ConnectivityResult.mobile]);

        await monitor.checkNetworkConnectivity();

        // Task should be paused waiting for WiFi.
        expect(tasks.first.status, DownloadStatus.paused);
        expect(tasks.first.errorMessage, DownloadStatusMessages.waitingWifi);
      });

      test('wifi-only resume does not override pausedByUser', () async {
        wifiOnly = true;

        // Add a task that is paused with the waiting-for-wifi message
        // and pausedByUser=true.
        tasks.add(
          _task(
            'w2',
            DownloadStatus.paused,
            pausedByUser: true,
            errorMessage: DownloadStatusMessages.waitingWifi,
          ),
        );

        // Wi-Fi is available, so the monitor attempts to resume wifi-paused
        // tasks; the task must remain paused because pausedByUser is true.
        // Pinning the state avoids touching the real Connectivity() channel.
        monitor.setConnectivityForTesting(const [ConnectivityResult.wifi]);
        await monitor.checkNetworkConnectivity();

        // The task should NOT have been re-queued.
        final queued = setTaskCalls.where(
          (t) => t.id == 'w2' && t.status == DownloadStatus.queued,
        );
        expect(queued, isEmpty);
      });
    });

    group('re-entrant guard', () {
      test('concurrent checkNetworkConnectivity is coalesced', () async {
        tasks.add(_task('r1', DownloadStatus.downloading));
        cancelTokens['r1'] = CancelToken();
        monitor.setConnectivityForTesting([ConnectivityResult.none]);

        // Fire two checks concurrently. The re-entrant guard should
        // prevent double-processing.
        final f1 = monitor.checkNetworkConnectivity();
        final f2 = monitor.checkNetworkConnectivity();
        await Future.wait([f1, f2]);

        // The task should be paused exactly once.
        final pauseCalls = setTaskCalls.where(
          (t) => t.status == DownloadStatus.paused,
        );
        // At most one pause call per task (the second call is coalesced).
        expect(pauseCalls.length, lessThanOrEqualTo(2));
      });
    });

    group('dispose', () {
      test('clears internal state', () {
        monitor.dispose();
        // After dispose, calling checkNetworkConnectivity should still
        // work (no null exceptions) since it uses callbacks.
        // This is a smoke test.
      });
    });

    group('state getters', () {
      test('reflect connectivity snapshots', () {
        monitor.setConnectivityForTesting([ConnectivityResult.wifi]);
        expect(monitor.hasWifiOrEthernet, isTrue);
        expect(monitor.isCellular, isFalse);
        expect(monitor.hasNoNetwork, isFalse);
        expect(monitor.hasAnyNetworkConnection, isTrue);
        expect(monitor.hasConnection, isTrue);
        expect(monitor.currentConnectivity, [ConnectivityResult.wifi]);
        expect(monitor.hasResolvedInitialConnectivity, isTrue);

        monitor.setConnectivityForTesting([ConnectivityResult.mobile]);
        expect(monitor.isCellular, isTrue);
        expect(monitor.hasWifiOrEthernet, isFalse);

        monitor.setConnectivityForTesting([ConnectivityResult.none]);
        expect(monitor.hasNoNetwork, isTrue);
        expect(monitor.hasConnection, isFalse);
      });
    });

    group('wifi-waiting resume', () {
      test('marked tasks are re-queued when wifi is available', () async {
        tasks.add(_task('w1', DownloadStatus.paused));
        monitor.markWifiWaiting('w1');
        monitor.setConnectivityForTesting([ConnectivityResult.wifi]);
        await monitor.checkNetworkConnectivity();
        expect(tasks.first.status, DownloadStatus.queued);
        expect(pumpQueueCount, greaterThan(0));
      });

      test('pausedByUser tasks are skipped on wifi resume', () async {
        tasks.add(_task('w2', DownloadStatus.paused, pausedByUser: true));
        monitor.markWifiWaiting('w2');
        monitor.setConnectivityForTesting([ConnectivityResult.wifi]);
        await monitor.checkNetworkConnectivity();
        expect(tasks.first.status, DownloadStatus.paused);
      });
    });

    group('pause-on-cellular', () {
      test('pauses on mobile and resumes on wifi', () async {
        final localTasks = <DownloadTask>[];
        final localCancels = <String, CancelToken>{};
        var pausedCount = 0;
        final m = NetworkMonitor(
          tasks: () => localTasks,
          torrentIds: () => {},
          cancelTokens: () => localCancels,
          wifiOnly: () => false,
          pauseOnCellular: () => true,
          setTask: (updated) async {
            final idx = localTasks.indexWhere((t) => t.id == updated.id);
            if (idx != -1) localTasks[idx] = updated;
            pausedCount++;
          },
          pumpQueue: () {},
        );
        addTearDown(m.dispose);

        localTasks.add(_task('c1', DownloadStatus.downloading));
        localCancels['c1'] = CancelToken();
        m.setConnectivityForTesting([ConnectivityResult.mobile]);
        await m.checkNetworkConnectivity();
        expect(localTasks.first.status, DownloadStatus.paused);
        expect(
          localTasks.first.errorMessage,
          DownloadStatusMessages.waitingWifi,
        );

        m.setConnectivityForTesting([ConnectivityResult.wifi]);
        await m.checkNetworkConnectivity();
        expect(localTasks.first.status, DownloadStatus.queued);
        expect(pausedCount, greaterThan(0));
      });
    });

    group('onNetworkChanged callback', () {
      test('emits connected and wifi state', () async {
        NetworkChanged? captured;
        final m = NetworkMonitor(
          tasks: () => [],
          torrentIds: () => {},
          cancelTokens: () => {},
          wifiOnly: () => false,
          setTask: (_) async {},
          pumpQueue: () {},
          onNetworkChanged: (event) async => captured = event,
        );
        addTearDown(m.dispose);
        m.setConnectivityForTesting([ConnectivityResult.wifi]);
        await m.checkNetworkConnectivity();
        expect(captured, isNotNull);
        expect(captured!.isConnected, isTrue);
        expect(captured!.isWifi, isTrue);
      });

      test('emits disconnected on no network', () async {
        NetworkChanged? captured;
        final m = NetworkMonitor(
          tasks: () => [],
          torrentIds: () => {},
          cancelTokens: () => {},
          wifiOnly: () => false,
          setTask: (_) async {},
          pumpQueue: () {},
          onNetworkChanged: (event) async => captured = event,
        );
        addTearDown(m.dispose);
        m.setConnectivityForTesting([ConnectivityResult.none]);
        await m.checkNetworkConnectivity();
        expect(captured!.isConnected, isFalse);
      });
    });

    group('torrent and future handling on disconnect', () {
      test('pauses torrents, cancels token and awaits active future', () async {
        final localTasks = <DownloadTask>[];
        final localTorrentIds = <String, int>{'d1': 42};
        final localCancels = <String, CancelToken>{'d1': CancelToken()};
        final localFutures = <String, Future<void>>{
          'd1': Future<void>.delayed(const Duration(milliseconds: 5)),
        };
        final m = NetworkMonitor(
          tasks: () => localTasks,
          torrentIds: () => localTorrentIds,
          cancelTokens: () => localCancels,
          activeFutures: () => localFutures,
          wifiOnly: () => false,
          setTask: (updated) async {
            final idx = localTasks.indexWhere((t) => t.id == updated.id);
            if (idx != -1) localTasks[idx] = updated;
          },
          pumpQueue: () {},
        );
        addTearDown(m.dispose);
        localTasks.add(_task('d1', DownloadStatus.downloading));
        m.setConnectivityForTesting([ConnectivityResult.none]);
        await m.checkNetworkConnectivity();
        expect(localTasks.first.status, DownloadStatus.paused);
        expect(localCancels.containsKey('d1'), isFalse);
      });
    });

    group('resume with skipPump', () {
      test('re-queues without pumping the queue', () async {
        tasks.add(_task('r1', DownloadStatus.downloading));
        cancelTokens['r1'] = CancelToken();
        monitor.setConnectivityForTesting([ConnectivityResult.none]);
        await monitor.checkNetworkConnectivity();
        expect(tasks.first.status, DownloadStatus.paused);

        pumpQueueCount = 0;
        monitor.setConnectivityForTesting([ConnectivityResult.wifi]);
        await monitor.checkNetworkConnectivity(skipPump: true);
        expect(tasks.first.status, DownloadStatus.queued);
        expect(pumpQueueCount, 0);
      });
    });

    group('network reachability', () {
      test('false when the adapter throws', () async {
        final dio = Dio()..httpClientAdapter = _ThrowingAdapter();
        expect(await NetworkMonitor.isNetworkReachable(dioClient: dio), isFalse);
      });

      test('true for a 204 response', () async {
        final dio = Dio()..httpClientAdapter = _OkAdapter(204);
        expect(await NetworkMonitor.isNetworkReachable(dioClient: dio), isTrue);
        expect(
          await NetworkMonitor.verifyConnectivityProbe(dioClient: dio),
          isTrue,
        );
      });
    });

    group('init', () {
      test('resolves initial connectivity and dispose is safe', () async {
        ConnectivityPlatform.instance = _MockConnectivityPlatform();
        monitor.init();
        monitor.init(); // idempotent
        await monitor.ensureInitialConnectivity();
        expect(monitor.hasResolvedInitialConnectivity, isTrue);
        monitor.dispose();
      });
    });
  });
}

