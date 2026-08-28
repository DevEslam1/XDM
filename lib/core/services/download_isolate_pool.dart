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
        PowerMonitor.screenOff ||
        PowerMonitor.batterySaverMode != BatterySaverMode.off ||
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

  void _dispatch(PoolJob job, int priority) {
    job.priority = priority;
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
      'jobId': job.command.taskId,
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
        final doneId = msg['jobId'];
        if (doneId != null && doneId is String) {
          _jobCrashCounts.remove(doneId);
        }
        worker.pending.removeWhere((j) => j.command.taskId == doneId);
        _drain();
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
          'jobId': job.command.taskId,
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
    var best = 0;
    for (var i = 1; i < _queue.length; i++) {
      final a = _queue[best];
      final b = _queue[i];
      if (b.priority > a.priority ||
          (b.priority == a.priority && b.seq < a.seq)) {
        best = i;
      }
    }
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

  void _cancelJob(PoolJob job, [PauseReason? reason]) {
    try {
      DownloadJournal.flushAndSyncForFile(job.command.tempFilePath);
    } catch (_) {}
    job._worker?.commandPort?.send({
      't': 'cancel',
      'jobId': job.command.taskId,
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
          DownloadJournal.flushAndSyncForFile(j.command.tempFilePath);
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
      // Re-queue surviving sibling jobs to a fresh worker.
      for (final job in remainingPending) {
        _queue.add(job);
      }
      // Use beforeNextEvent first to allow isolate to finish any in-flight buffer flush,
      // with a 2-second fallback timer before hard killing.
      worker.disposeResources(killPriority: Isolate.beforeNextEvent);
      final isolateToKill = worker.isolate;
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
          return true;
        }
        return false;
      });
    }
  }

  void updateSpeedLimit(int bytesPerSecond, int activeCount) {
    for (final w in _workers) {
      w.commandPort
          ?.send({'t': 'limits', 'bps': bytesPerSecond, 'active': activeCount});
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
    _queue.clear();
    for (final w in _workers) {
      w.commandPort?.send({'t': 'shutdown'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
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
    _queue.clear();
    for (final w in _workers) {
      w.dead = true;
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
  PoolJob._(this._pool, this.command, this._seq) {
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
  }
  final DownloadIsolatePool _pool;
  final DownloadCommand command;
  final int _seq;
  int priority = 0;
  int get seq => _seq;
  final ReceivePort _incoming = ReceivePort();
  _Worker? _worker;
  late final Stream<EngineMessage> messages;
  bool _disposed = false;
  void cancel([PauseReason? reason]) => _pool._cancelJob(this, reason);
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
    _incoming.close();
  }
}
