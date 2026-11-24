part of 'download_engine.dart';

class EngineMessage {
  EngineMessage._(this.type, this.taskId, this.data, this.seq);
  static const int protocolVersion = 1;
  final EngineMessageType type;
  final String taskId;
  final Map<String, dynamic> data;
  final int seq;
  static Map<String, dynamic> encode({
    required EngineMessageType type,
    required String taskId,
    int seq = 0,
    Map<String, dynamic>? data,
  }) =>
      {
        'proto': protocolVersion,
        'type': type.name,
        'taskId': taskId,
        'seq': seq,
        if (data != null) 'data': data,
      };
  static EngineMessage? tryDecode(dynamic raw) {
    try {
      if (raw is! Map) return null;
      if (raw['proto'] != protocolVersion) return null;
      final type = EngineMessageType.fromWire(raw['type']);
      final taskId = raw['taskId'];
      if (type == null || taskId is! String) return null;
      final data = raw['data'];
      return EngineMessage._(
        type,
        taskId,
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
        (raw['seq'] as num?)?.toInt() ?? 0,
      );
    } catch (e, st) {
      LoggingService.logger('DownloadIsolatePool')
          .warning('Operation failed with fallback', e, st);
      return null;
    }
  }
}

class PoolMetrics {
  final int totalWorkers;
  final int busyWorkers;
  final int idleWorkers;
  final int queuedJobs;
  final int completedJobs;
  final int failedJobs;

  const PoolMetrics({
    required this.totalWorkers,
    required this.busyWorkers,
    required this.idleWorkers,
    required this.queuedJobs,
    required this.completedJobs,
    required this.failedJobs,
  });

  @override
  String toString() =>
      'PoolMetrics(totalWorkers: $totalWorkers, busyWorkers: $busyWorkers, idleWorkers: $idleWorkers, queuedJobs: $queuedJobs, completedJobs: $completedJobs, failedJobs: $failedJobs)';
}

class DownloadIsolatePool implements MemoryPressureListener {
  DownloadIsolatePool({
    int size = 4,
    int? maxPoolSize,
    bool powerAware = false,
  })  : _size = maxPoolSize != null ? min(size, maxPoolSize) : size,
        _maxPoolSize = maxPoolSize,
        _powerAware = powerAware;
  final int _size;
  final int? _maxPoolSize;
  final bool _powerAware;
  final List<_Worker> _workers = [];
  final List<PoolJob> _queue = [];

  /// ERR-RESILIENCE-2.3: Tracks how many times a job's worker crashed so we can
  /// re-queue (transient) then permanently fail (repeated native crashes).
  final Map<String, int> _jobCrashCounts = {};
  static const int _maxJobCrashRetries = 3;

  int _completedJobs = 0;
  int _failedJobs = 0;

  void reportJobCompleted() => _completedJobs++;
  void reportJobFailed() => _failedJobs++;

  PoolMetrics get poolMetrics {
    final busy = _workers.where((w) => !w.dead && w.activeJobs > 0).length;
    final idle = _workers.where((w) => !w.dead && w.activeJobs == 0).length;
    return PoolMetrics(
      totalWorkers: _workers.length,
      busyWorkers: busy,
      idleWorkers: idle,
      queuedJobs: _queue.length,
      completedJobs: _completedJobs,
      failedJobs: _failedJobs,
    );
  }

  bool _shuttingDown = false;
  bool _draining = false;
  int _seq = 0;
  int _flushReqSeq = 0;
  final Map<int, Completer<void>> _flushCompleters = {};
  int get maxJobsPerWorker =>
      PowerMonitor.batterySaverMode == BatterySaverMode.aggressive ? 1 : 2;
  int get workerCount {
    final live = _workers.length;
    if (live <= 0) return 0;
    if (_powerAwareActive &&
        PowerMonitor.batterySaverMode == BatterySaverMode.aggressive) {
      return 1;
    }
    return live;
  }

  bool _isSpawning = false;
  Timer? _idleCheckTimer;
  Timer? _sweepCrashCountsTimer;
  Timer? _bgIdleReaper;
  bool _foregroundListenerAttached = false;

  bool get _powerAwareActive =>
      _powerAware && SettingsProvider.instance.powerAwareIsolatePool;

  int get effectiveMaxSize {
    if (DownloadEngine.isInBackground) return 1;
    if (!_powerAwareActive) {
      return _maxPoolSize != null ? min(_size, _maxPoolSize!) : _size;
    }
    if (PowerMonitor.screenOff || PowerMonitor.isLowEndDevice) return 1;
    if (PowerMonitor.batterySaverMode == BatterySaverMode.aggressive ||
        PowerMonitor.thermal == ThermalStatus.severe ||
        PowerMonitor.thermal == ThermalStatus.critical) {
      return 1;
    }
    if (PowerMonitor.batteryLevel < 15) return 1;

    if (PowerMonitor.batterySaverMode == BatterySaverMode.moderate) {
      final modCap = min(2, _size);
      return _maxPoolSize != null ? min(modCap, _maxPoolSize!) : modCap;
    }

    if (PowerMonitor.isCharging) {
      return _maxPoolSize != null ? min(_size, _maxPoolSize!) : _size;
    }
    if (PowerMonitor.batteryLevel < 20) {
      return 1;
    }
    return _maxPoolSize != null ? min(_size, _maxPoolSize!) : _size;
  }

  Future<void> init() async {
    if (_workers.isEmpty) {
      final maxWorkers = effectiveMaxSize;
      for (var i = 0; i < maxWorkers; i++) {
        _workers.add(await _spawnWorker(i));
      }
    }
    _startIdleCheckTimer();
    _startCrashCountSweepTimer();
    if (!_foregroundListenerAttached) {
      _foregroundListenerAttached = true;
      DownloadEngine.appInForegroundNotifier.addListener(_onForegroundChanged);
    }
    if (DownloadEngine.isInBackground) {
      _startBgIdleReaper();
    }
  }

  void _onForegroundChanged() {
    if (DownloadEngine.appInForeground) {
      _stopBgIdleReaper();
      // On foreground return, respawn workers up to effectiveMaxSize
      _maybeExpandWorkers();
    } else {
      _startBgIdleReaper();
    }
  }

  void _stopBgIdleReaper() {
    TickManager.instance.unregisterTick('isolate_pool_bg_reaper');
    _bgIdleReaper?.cancel();
    _bgIdleReaper = null;
  }

  void _startBgIdleReaper() {
    _stopBgIdleReaper();
    // FIX P0-11: Use distinct tick id. Previously both bg-reaper and
    // idle-check used 'isolate_pool_idle_check', causing overwrite —
    // one timer silently lost, leaking or killing workers.
    TickManager.instance.registerTick(
      id: 'isolate_pool_bg_reaper',
      interval: const Duration(seconds: 60),
      priority: TickPriority.normal,
      callback: (_) {
        _reapBackgroundIdleWorkers();
      },
    );
  }

  void _reapBackgroundIdleWorkers() {
    if (_shuttingDown || _workers.length <= 1) return;
    if (!DownloadEngine.isInBackground) return;

    final toRemove = <_Worker>[];
    for (final w in _workers) {
      if (w.activeJobs == 0 && !w.dead && w.pending.isEmpty) {
        w.dead = true;
        toRemove.add(w);
        if (_workers.length - toRemove.length <= 1) break;
      }
    }

    for (final w in toRemove) {
      _workers.remove(w);
      try {
        w.commandPort?.send({'t': 'shutdown'});
      } catch (e, st) {
        LoggingService.logger('DownloadIsolatePool')
            .warning('Operation failed', e, st);
      }
      w.disposeResources(killPriority: Isolate.beforeNextEvent);
    }
  }

  void _startCrashCountSweepTimer() {
    _sweepCrashCountsTimer?.cancel();
    _sweepCrashCountsTimer = null;
    TickManager.instance.registerTick(
      id: 'isolate_pool_crash_sweep',
      interval: const Duration(minutes: 5),
      priority: TickPriority.critical,
      callback: (_) {
        _jobCrashCounts
            .removeWhere((taskId, _) => !_isJobActiveOrQueued(taskId));
      },
    );
  }

  void _startIdleCheckTimer() {
    _idleCheckTimer?.cancel();
    _idleCheckTimer = null;
    final interval = (DownloadEngine.isInBackground || PowerMonitor.screenOff)
        ? const Duration(seconds: 60)
        : const Duration(seconds: 15);
    TickManager.instance.registerTick(
      id: 'isolate_pool_idle_check',
      interval: interval,
      priority: TickPriority.normal,
      callback: (_) {
        _checkIdleWorkers();
      },
    );
  }

  void _checkIdleWorkers() {
    if (_shuttingDown || _workers.length <= 1) return;
    final now = DateTime.now();
    final toRemove = <_Worker>[];
    final isPowerConstrained = _powerAwareActive &&
        (PowerMonitor.batterySaverMode == BatterySaverMode.aggressive ||
            PowerMonitor.screenOff ||
            _workers.length > effectiveMaxSize);
    final idleThreshold = DownloadEngine.isInBackground
        ? const Duration(seconds: 30)
        : isPowerConstrained
            ? const Duration(seconds: 5)
            : const Duration(seconds: 30);

    for (final w in _workers) {
      if (w.activeJobs == 0 &&
          !w.dead &&
          w.pending.isEmpty &&
          now.difference(w.lastActiveTime) > idleThreshold) {
        w.dead = true;
        toRemove.add(w);
        if (_workers.length - toRemove.length <= 1) break;
      }
    }

    for (final w in toRemove) {
      _workers.remove(w);
      try {
        w.commandPort?.send({'t': 'shutdown'});
      } catch (e, st) {
        LoggingService.logger('DownloadIsolatePool')
            .warning('Operation failed', e, st);
      }
      w.disposeResources(killPriority: Isolate.beforeNextEvent);
    }
  }

  Future<_Worker> _spawnWorker(int index) async {
    final inbox = ReceivePort();
    final errorPort = ReceivePort();
    final isolate = await Isolate.spawn(
      workerEntry,
      inbox.sendPort,
      errorsAreFatal: true,
      onError: errorPort.sendPort,
      debugName: 'dmx-engine-worker-$index',
    );
    final worker =
        _Worker(isolate: isolate, inbox: inbox, errorPort: errorPort);
    inbox.listen((dynamic msg) => _onWorkerMessage(worker, msg));
    errorPort.listen((dynamic err) => _onWorkerCrash(worker, err));
    return worker;
  }

  Future<void> _maybeExpandWorkers() async {
    if (_isSpawning ||
        _shuttingDown ||
        (_powerAwareActive &&
            (PowerMonitor.screenOff ||
                PowerMonitor.batterySaverMode != BatterySaverMode.off)) ||
        _workers.length >= effectiveMaxSize) {
      return;
    }
    _isSpawning = true;
    try {
      final newIndex = _workers.length;
      final worker = await _spawnWorker(newIndex);
      if (!_shuttingDown) {
        _workers.add(worker);
      } else {
        worker.disposeResources(killPriority: Isolate.immediate);
      }
    } catch (e, st) {
      LoggingService.logger('DownloadIsolatePool')
          .warning('Operation failed', e, st);
    } finally {
      _isSpawning = false;
      _drain();
    }
  }

  PoolJob submit(DownloadCommand command, {int priority = 0}) {
    if (_shuttingDown) {
      throw const IsolateSpawnTimeoutException();
    }
    final job = PoolJob._(this, command, _seq++);
    if (_shuttingDown) {
      scheduleMicrotask(() =>
          job._deliverError('workerDied', 'Engine is shutting down', null));
      return job;
    }
    _dispatch(job, priority);
    return job;
  }

  bool _hasActiveWorkerJobForTask(String taskId) {
    for (final w in _workers) {
      if (!w.dead && w.pending.any((j) => j.command.taskId == taskId)) {
        return true;
      }
    }
    return false;
  }

  void _dispatch(PoolJob job, int priority) {
    job.priority = priority;
    if (_hasActiveWorkerJobForTask(job.command.taskId)) {
      _queue.add(job);
      return;
    }
    final slots = maxJobsPerWorker;
    _Worker? worker;
    int minLoad = slots;
    for (final w in _workers) {
      if (!w.dead && w.commandPort != null && w.activeJobs < minLoad) {
        minLoad = w.activeJobs;
        worker = w;
      }
    }
    if (worker == null) {
      _queue.add(job);
      if (_workers.length < effectiveMaxSize) {
        _maybeExpandWorkers();
      }
      return;
    }
    worker.activeJobs++;
    worker.pending.add(job);
    worker.lastActiveTime = DateTime.now();
    job._worker = worker;
    worker.commandPort?.send({
      't': 'job',
      'jobId': job.runId,
      'taskId': job.command.taskId,
      'reply': job._incoming.sendPort,
      'cmd': job.command.toMap(),
    });
  }

  void _onWorkerMessage(_Worker worker, dynamic msg) {
    if (msg is! Map) return;
    switch (msg['t']) {
      case 'hello':
        worker.commandPort = msg['port'] as SendPort;
        _drain();
      case 'idle':
        worker.activeJobs = (worker.activeJobs - 1).clamp(0, 1 << 30);
        if (worker.activeJobs == 0) {
          worker.lastActiveTime = DateTime.now();
        }
        final doneRunId = msg['jobId'];
        final doneTaskId = msg['taskId'] as String?;
        if (doneTaskId != null) {
          _jobCrashCounts.remove(doneTaskId);
        } else if (doneRunId is String) {
          _jobCrashCounts.remove(doneRunId);
        }
        worker.pending.removeWhere(
            (j) => j.runId == doneRunId || j.command.taskId == doneRunId);
        _drain();
      case 'flushed':
        final reqId = msg['reqId'];
        if (reqId is int) {
          final c = _flushCompleters.remove(reqId);
          if (c != null && !c.isCompleted) c.complete();
        }
      case 'limits':
        break;
    }
  }

  void _drain() {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final slots = maxJobsPerWorker;
        _Worker? worker;
        for (final w in _workers) {
          if (!w.dead && w.commandPort != null && w.activeJobs < slots) {
            worker = w;
            break;
          }
        }
        if (worker == null) {
          if (_workers.length < effectiveMaxSize) {
            _maybeExpandWorkers();
          }
          return;
        }
        final job = _removeHighestPriority();
        if (job == null) return;
        worker.activeJobs++;
        worker.pending.add(job);
        worker.lastActiveTime = DateTime.now();
        job._worker = worker;
        worker.commandPort!.send({
          't': 'job',
          'jobId': job.runId,
          'taskId': job.command.taskId,
          'reply': job._incoming.sendPort,
          'cmd': job.command.toMap(),
        });
      }
    } finally {
      _draining = false;
    }
  }

  PoolJob? _removeHighestPriority() {
    if (_queue.isEmpty) return null;
    var best = -1;
    for (var i = 0; i < _queue.length; i++) {
      final b = _queue[i];
      if (_hasActiveWorkerJobForTask(b.command.taskId)) continue;
      if (best == -1) {
        best = i;
        continue;
      }
      final a = _queue[best];
      if (b.priority > a.priority ||
          (b.priority == a.priority && b.seq < a.seq)) {
        best = i;
      }
    }
    if (best == -1) return null;
    return _queue.removeAt(best);
  }

  void _onWorkerCrash(_Worker worker, dynamic err) {
    worker.dead = true;
    final jobs = List<PoolJob>.from(worker.pending);
    worker.pending.clear();
    worker.activeJobs = 0;
    for (final job in jobs) {
      // ERR-RESILIENCE-2.3: Re-queue jobs that died with the worker (up to 3
      // crashes per job). A worker isolate crash is usually a transient native
      // hiccup — the download's .dmxstate/journal survive on disk, so a fresh
      // worker can resume cleanly. Permanent failures after 3 crashes are
      // delivered so the task can be failed with a meaningful message.
      final crashes = (_jobCrashCounts[job.command.taskId] ?? 0) + 1;
      _jobCrashCounts[job.command.taskId] = crashes;
      if (crashes <= _maxJobCrashRetries && !_shuttingDown) {
        debugPrint(
          '[DMX-Pool] Worker died for job ${job.command.taskId} '
          '(crash #$crashes). Re-queuing.',
        );
        job._worker = null;
        _queue.add(job);
      } else {
        _jobCrashCounts.remove(job.command.taskId);
        job._deliverError(
          'workerDied',
          'Worker isolate died repeatedly: $err',
          null,
        );
        Future<void>.delayed(const Duration(milliseconds: 500), () {
          job.dispose();
        });
      }
    }
    worker.disposeResources(killPriority: Isolate.immediate);
    if (!_shuttingDown) {
      _workers.remove(worker);
      Future.microtask(() async {
        if (_shuttingDown) return;
        if (_workers.isEmpty) {
          try {
            final w = await _spawnWorker(0);
            _workers.add(w);
            _drain();
          } catch (e, st) {
            LoggingService.logger('DownloadIsolatePool')
                .warning('Failed to respawn worker after crash', e, st);
          }
        } else {
          _drain();
        }
      });
    }
  }

  Future<void> flushActiveJobs(
      {Duration timeout = const Duration(milliseconds: 800)}) async {
    if (_shuttingDown) return;
    final busyWorkers = _workers
        .where((w) => !w.dead && w.commandPort != null && w.pending.isNotEmpty)
        .toList(growable: false);
    if (busyWorkers.isEmpty) return;
    final futures = <Future<void>>[];
    for (final w in busyWorkers) {
      final reqId = ++_flushReqSeq;
      final completer = Completer<void>();
      _flushCompleters[reqId] = completer;
      try {
        w.commandPort!.send({'t': 'flush', 'reqId': reqId});
        futures.add(completer.future);
      } catch (_) {
        _flushCompleters.remove(reqId);
      }
    }
    if (futures.isEmpty) return;
    try {
      await Future.wait(futures).timeout(timeout);
    } catch (_) {
    } finally {
      for (final c in _flushCompleters.values.toList()) {
        if (!c.isCompleted) c.complete();
      }
      _flushCompleters.clear();
    }
  }

  void _cancelJob(PoolJob job, [PauseReason? reason]) {
    try {
      DownloadJournal.flushAndSyncForFile(job.command.tempFilePath,
          taskId: job.command.taskId);
    } catch (_) {}
    if (job._worker == null) {
      _queue.remove(job);
      job._deliverError('cancel', 'Job cancelled while queued', null);
      return;
    }
    job._worker?.commandPort?.send({
      't': 'cancel',
      'jobId': job.runId,
      'taskId': job.command.taskId,
      if (reason != null) 'reason': reason.name,
    });
  }

  void forceCancelJob(String taskId) {
    _Worker? worker;
    for (final w in _workers) {
      if (w.pending.any((j) => j.command.taskId == taskId)) {
        worker = w;
        break;
      }
    }
    if (worker != null) {
      debugPrint(
          '[DMX-Pool] forceCancelJob: killing worker isolate for task $taskId');
      final targetJobs =
          worker.pending.where((j) => j.command.taskId == taskId).toList();
      for (final j in targetJobs) {
        try {
          DownloadJournal.flushAndSyncForFile(j.command.tempFilePath,
              taskId: j.command.taskId);
        } catch (_) {}
      }
      worker.dead = true;
      // FIX(H-3): Only error the TARGET task's jobs. Previously every pending
      // job on the worker was error-killed, so a healthy sibling task sharing
      // the same worker was also marked "forceCancelled" → DB writes
      // status=failed → user sees a perfectly fine task jump to failed state.
      final remainingPending =
          worker.pending.where((j) => j.command.taskId != taskId).toList();
      worker.pending.clear();
      worker.activeJobs = 0;
      for (final job in targetJobs) {
        job._deliverError(
          'forceCancelled',
          'Worker isolate killed due to cancel timeout',
          null,
        );
      }
      // Re-queue surviving sibling jobs to a fresh worker only if not cancelled or disposed.
      for (final job in remainingPending) {
        job._worker = null;
        if (!job._disposed && !job._cancelled) {
          _queue.add(job);
        } else {
          job._deliverError(
            'cancelled',
            'Job was cancelled',
            null,
          );
        }
      }
      // Capture isolate reference BEFORE disposeResources() clears worker.isolate,
      // so the 2-second Isolate.immediate fallback timer can actually hard-kill it.
      final isolateToKill = worker.isolate;
      worker.disposeResources(killPriority: Isolate.beforeNextEvent);
      if (isolateToKill != null) {
        Timer(const Duration(seconds: 2), () {
          try {
            isolateToKill.kill(priority: Isolate.immediate);
          } catch (_) {}
        });
      }
      if (!_shuttingDown) {
        _workers.remove(worker);
        Future.microtask(() async {
          if (_shuttingDown) return;
          if (_workers.isEmpty) {
            try {
              final w = await _spawnWorker(0);
              _workers.add(w);
              _drain();
            } catch (e, st) {
              LoggingService.logger('DownloadIsolatePool').warning(
                  'Failed to respawn worker after force cancel', e, st);
            }
          } else {
            _drain();
          }
        });
      }
    } else {
      _queue.removeWhere((job) {
        if (job.command.taskId == taskId) {
          job._deliverError('forceCancelled', 'Job removed from queue', null);
          Future<void>.delayed(const Duration(milliseconds: 500), () {
            job.dispose();
          });
          return true;
        }
        return false;
      });
    }
  }

  int _globalLimitBps = 0;
  final Map<String, int> _jobSpeeds = {};

  void _recordJobSpeed(String taskId, int speed) {
    if (speed > 0) {
      _jobSpeeds[taskId] = speed;
      _rebalanceBandwidth();
    }
  }

  void _removeJobSpeed(String taskId) {
    _jobSpeeds.remove(taskId);
    _rebalanceBandwidth();
  }

  void updateSpeedLimit(int bytesPerSecond, int activeCount) {
    _globalLimitBps = bytesPerSecond;
    _rebalanceBandwidth(activeCount);
  }

  void _rebalanceBandwidth([int? explicitActiveCount]) {
    final activeJobs = <PoolJob>[];
    for (final w in _workers) {
      if (!w.dead) {
        activeJobs.addAll(w.pending);
      }
    }
    final count = explicitActiveCount ?? activeJobs.length;
    if (_globalLimitBps <= 0 || count <= 0) {
      for (final w in _workers) {
        w.commandPort?.send({'t': 'limits', 'bps': 0, 'active': 1});
      }
      return;
    }

    if (activeJobs.length <= 1) {
      // Single active job receives 100% of the global budget!
      for (final w in _workers) {
        w.commandPort
            ?.send({'t': 'limits', 'bps': _globalLimitBps, 'active': 1});
      }
      return;
    }

    // Work-conserving dynamic budget allocation across multiple active downloads:
    final fairShare = (_globalLimitBps / activeJobs.length).floor();
    var surplus = 0;
    final demandingJobs = <PoolJob>[];
    final grants = <String, int>{};

    for (final job in activeJobs) {
      final measured = _jobSpeeds[job.command.taskId] ?? 0;
      // If a job's measured speed is substantially lower than its fair share (e.g. capped by origin server),
      // allocate measured speed + 25% headroom and return surplus to the pool.
      if (measured > 0 && measured < (fairShare * 0.75)) {
        final cappedGrant = (measured * 1.25).toInt();
        grants[job.command.taskId] = cappedGrant;
        surplus += (fairShare - cappedGrant);
      } else {
        demandingJobs.add(job);
      }
    }

    final extraPerJob =
        demandingJobs.isNotEmpty ? (surplus ~/ demandingJobs.length) : 0;
    for (final job in demandingJobs) {
      grants[job.command.taskId] = fairShare + extraPerJob;
    }

    for (final w in _workers) {
      if (w.dead || w.commandPort == null) continue;
      if (w.pending.isNotEmpty) {
        final job = w.pending.first;
        final grant = grants[job.command.taskId] ?? fairShare;
        w.commandPort?.send({'t': 'limits', 'bps': grant, 'active': 1});
      } else {
        w.commandPort?.send({'t': 'limits', 'bps': fairShare, 'active': 1});
      }
    }
  }

  Future<void> shutdown() async {
    _shuttingDown = true;
    _idleCheckTimer?.cancel();
    _idleCheckTimer = null;
    _sweepCrashCountsTimer?.cancel();
    _sweepCrashCountsTimer = null;
    _bgIdleReaper?.cancel();
    _bgIdleReaper = null;
    TickManager.instance.unregisterTick('isolate_pool_crash_sweep');
    TickManager.instance.unregisterTick('isolate_pool_idle_check');
    TickManager.instance.unregisterTick('isolate_pool_bg_reaper');
    if (_foregroundListenerAttached) {
      DownloadEngine.appInForegroundNotifier
          .removeListener(_onForegroundChanged);
      _foregroundListenerAttached = false;
    }
    for (final job in _queue) {
      job.dispose();
    }
    _queue.clear();
    for (final c in _flushCompleters.values) {
      if (!c.isCompleted) c.complete();
    }
    _flushCompleters.clear();
    for (final w in _workers) {
      w.commandPort?.send({'t': 'shutdown'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (final job in w.pending) {
        job.dispose();
      }
      w.pending.clear();
      w.disposeResources(killPriority: Isolate.beforeNextEvent);
    }
    _workers.clear();
  }

  void forceKillAll() {
    _shuttingDown = true;
    _idleCheckTimer?.cancel();
    _idleCheckTimer = null;
    _sweepCrashCountsTimer?.cancel();
    _sweepCrashCountsTimer = null;
    _bgIdleReaper?.cancel();
    _bgIdleReaper = null;
    TickManager.instance.unregisterTick('isolate_pool_crash_sweep');
    TickManager.instance.unregisterTick('isolate_pool_idle_check');
    TickManager.instance.unregisterTick('isolate_pool_bg_reaper');
    if (_foregroundListenerAttached) {
      try {
        DownloadEngine.appInForegroundNotifier
            .removeListener(_onForegroundChanged);
      } catch (_) {}
      _foregroundListenerAttached = false;
    }
    for (final job in _queue) {
      job.dispose();
    }
    _queue.clear();
    for (final c in _flushCompleters.values) {
      if (!c.isCompleted) c.complete();
    }
    _flushCompleters.clear();
    for (final w in _workers) {
      w.dead = true;
      for (final job in w.pending) {
        job.dispose();
      }
      w.pending.clear();
      w.disposeResources(killPriority: Isolate.immediate);
    }
    _workers.clear();
  }

  Future<void> dispose() async {
    await shutdown();
  }

  Future<void> drain({Duration? timeout}) async {
    await shutdown();
  }

  bool _isJobActiveOrQueued(String taskId) {
    if (_queue.any((j) => j.command.taskId == taskId)) return true;
    for (final w in _workers) {
      if (w.pending.any((j) => j.command.taskId == taskId)) return true;
    }
    return false;
  }

  @override
  void onMemoryPressure() {
    // FIX-1.5: Clear _jobCrashCounts for completed / non-active jobs
    _jobCrashCounts.removeWhere((taskId, _) => !_isJobActiveOrQueued(taskId));
    if (_workers.length > 1) {
      final idleIndex = _workers
          .lastIndexWhere((w) => w.activeJobs == 0 && w.pending.isEmpty);
      if (idleIndex != -1) {
        final w = _workers.removeAt(idleIndex);
        w.disposeResources(killPriority: Isolate.beforeNextEvent);
      }
    }
  }
}

class _Worker {
  _Worker({
    required this.isolate,
    required this.inbox,
    required this.errorPort,
  });
  Isolate? isolate;
  ReceivePort? inbox;
  ReceivePort? errorPort;
  SendPort? commandPort;
  final List<PoolJob> pending = [];
  int activeJobs = 0;
  bool dead = false;
  DateTime lastActiveTime = DateTime.now();

  void disposeResources({int killPriority = Isolate.immediate}) {
    try {
      inbox?.close();
    } catch (e, st) {
      LoggingService.logger('DownloadIsolatePool')
          .warning('Failed to close worker inbox', e, st);
    }
    try {
      errorPort?.close();
    } catch (e, st) {
      LoggingService.logger('DownloadIsolatePool')
          .warning('Failed to close worker errorPort', e, st);
    }
    try {
      isolate?.kill(priority: killPriority);
    } catch (e, st) {
      LoggingService.logger('DownloadIsolatePool')
          .warning('Failed to kill worker isolate', e, st);
    }
    inbox = null;
    errorPort = null;
    isolate = null;
    commandPort = null;
  }
}

class PoolChunkResult {
  const PoolChunkResult({
    required this.chunk,
    required this.success,
    this.error,
    this.stackTrace,
    this.attempts = 1,
  });

  final ChunkState chunk;
  final bool success;
  final Object? error;
  final StackTrace? stackTrace;
  final int attempts;
}

class PoolJob {
  static final Finalizer<ReceivePort> _portFinalizer = Finalizer((port) {
    try {
      port.close();
    } catch (_) {}
  });

  PoolJob._(this._pool, this.command, this._seq) {
    _portFinalizer.attach(this, _incoming, detach: this);
    messages = _incoming
        .map(EngineMessage.tryDecode)
        .where((m) {
          if (m == null) {
            debugPrint('[DMX-Pool] dropped undecodable engine message');
            return false;
          }
          return true;
        })
        .cast<EngineMessage>()
        .asBroadcastStream();
    messages.listen((msg) {
      if (msg.type == EngineMessageType.progress) {
        final speed = (msg.data['speed'] as num?)?.toInt() ?? 0;
        _pool._recordJobSpeed(command.taskId, speed);
      }
    });
  }
  final DownloadIsolatePool _pool;
  final DownloadCommand command;
  final int _seq;
  String get runId => '${command.taskId}#$_seq';
  int priority = 0;
  int get seq => _seq;
  final ReceivePort _incoming = ReceivePort();
  _Worker? _worker;
  late final Stream<EngineMessage> messages;
  bool _disposed = false;
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel([PauseReason? reason]) {
    _cancelled = true;
    _pool._cancelJob(this, reason);
  }
  void _deliverError(String type, String message, int? status) {
    if (_disposed) return;
    _incoming.sendPort.send(EngineMessage.encode(
      type: EngineMessageType.error,
      taskId: command.taskId,
      data: {'errorType': type, 'errorMessage': message, 'errorStatus': status},
    ));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _portFinalizer.detach(this);
    _pool._removeJobSpeed(command.taskId);
    try {
      _incoming.close();
    } catch (_) {}
  }
}
