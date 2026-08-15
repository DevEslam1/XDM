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
      LoggingService.logger('DownloadIsolatePool').warning('Operation failed with fallback', e, st);
      return null;
    }
  }
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

  bool _shuttingDown = false;
  int _seq = 0;
  int get maxJobsPerWorker =>
      PowerMonitor.batterySaverMode == BatterySaverMode.aggressive ? 1 : 2;
  int get workerCount {
    final live = _workers.length;
    if (live <= 0) return 0;
    if (_powerAware &&
        PowerMonitor.batterySaverMode == BatterySaverMode.aggressive) {
      return 1;
    }
    return live;
  }

  bool _isSpawning = false;
  Timer? _idleCheckTimer;
  Timer? _sweepCrashCountsTimer;

  int get effectiveMaxSize {
    if (PowerMonitor.screenOff) {
      return 1;
    }
    if (DownloadEngine.isInBackground) {
      final bgCap = min(2, _size);
      return _maxPoolSize != null ? min(bgCap, _maxPoolSize!) : bgCap;
    }
    if (_powerAware) {
      if (PowerMonitor.isCharging) {
        return _maxPoolSize != null ? min(_size, _maxPoolSize!) : _size;
      }
      if (PowerMonitor.batterySaverMode == BatterySaverMode.aggressive ||
          PowerMonitor.thermal == ThermalStatus.severe ||
          PowerMonitor.thermal == ThermalStatus.critical) {
        return 1;
      }
      if (PowerMonitor.batteryLevel < 20) {
        return 1;
      }
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
  }

  void _startCrashCountSweepTimer() {
    _sweepCrashCountsTimer?.cancel();
    _sweepCrashCountsTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _jobCrashCounts.removeWhere((taskId, _) => !_isJobActiveOrQueued(taskId));
    });
  }

  void _startIdleCheckTimer() {
    _idleCheckTimer?.cancel();
    _idleCheckTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _checkIdleWorkers();
    });
  }

  void _checkIdleWorkers() {
    if (_shuttingDown || _workers.length <= 1) return;
    final now = DateTime.now();
    final toRemove = <_Worker>[];
    final isPowerConstrained = _powerAware &&
        (PowerMonitor.batterySaverMode == BatterySaverMode.aggressive ||
            PowerMonitor.screenOff ||
            _workers.length > effectiveMaxSize);
    final idleThreshold = isPowerConstrained
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
      LoggingService.logger('DownloadIsolatePool').warning('Operation failed', e, st);
    }
      w.inbox.close();
      w.errorPort.close();
      w.isolate.kill(priority: Isolate.beforeNextEvent);
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
        worker.inbox.close();
        worker.errorPort.close();
        worker.isolate.kill(priority: Isolate.immediate);
      }
    } catch (e, st) {
      LoggingService.logger('DownloadIsolatePool').warning('Operation failed', e, st);
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
    for (final w in _workers) {
      if (!w.dead && w.commandPort != null && w.activeJobs < slots) {
        worker = w;
        break;
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
    worker.inbox.close();
    worker.errorPort.close();
    worker.isolate.kill(priority: Isolate.immediate);
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

  void _cancelJob(PoolJob job) {
    job._worker?.commandPort
        ?.send({'t': 'cancel', 'jobId': job.command.taskId});
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
    _queue.clear();
    for (final w in _workers) {
      w.commandPort?.send({'t': 'shutdown'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      w.inbox.close();
      w.errorPort.close();
      w.isolate.kill(priority: Isolate.beforeNextEvent);
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
        w.inbox.close();
        w.errorPort.close();
        w.isolate.kill(priority: Isolate.beforeNextEvent);
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
  final Isolate isolate;
  final ReceivePort inbox;
  final ReceivePort errorPort;
  SendPort? commandPort;
  final List<PoolJob> pending = [];
  int activeJobs = 0;
  bool dead = false;
  DateTime lastActiveTime = DateTime.now();
}

class ChunkResult {
  const ChunkResult({
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
  void cancel() => _pool._cancelJob(this);
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
