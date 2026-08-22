import 'dart:async';
import '../../interfaces/i_torrent_native.dart';
import '../diagnostic_service.dart';

/// Deterministic, scriptable implementation of [ITorrentNative] for unit and contract tests.
class FakeTorrentNative implements ITorrentNative {
  bool _initialized = true;
  String _libraryVersion = 'libtorrent/2.1.1-fake';
  int _nextId = 1;

  final StreamController<NativeAlertEvent> _alertCtrl =
      StreamController<NativeAlertEvent>.broadcast();
  final StreamController<Map<int, NativeTorrentStatus>> _statusCtrl =
      StreamController<Map<int, NativeTorrentStatus>>.broadcast();

  final Map<int, NativeTorrentStatus> _statuses = {};
  final Map<int, List<NativeFileInfo>> _files = {};
  final Map<int, List<int>> _filePriorities = {};
  final Map<int, List<int>> _fileProgress = {};
  final Map<int, List<NativeTrackerInfo>> _trackers = {};
  final Map<int, List<String>> _webSeeds = {};
  final Set<int> _sequential = {};
  final Set<int> _superSeeding = {};
  final Map<int, List<int>> _savedResumeData = {};

  bool simulateGracefulPauseTimeout = false;
  Duration gracefulPauseDelay = Duration.zero;
  bool simulateResumeLoadFailure = false;

  // FIX(N3): Injectable telemetry recorder to isolate DiagnosticService in tests
  void Function(String event, {String? taskId, String? details})? onTelemetryAlert;

  void _recordTelemetry(String event, {String? taskId, String? details}) {
    if (onTelemetryAlert != null) {
      onTelemetryAlert!(event, taskId: taskId, details: details);
    } else {
      try {
        DiagnosticService.instance.recordTelemetryAlert(event, taskId: taskId, details: details);
      } catch (_) {}
    }
  }

  @override
  bool get isInitialized => _initialized;

  @override
  String get libraryVersion => _libraryVersion;

  set libraryVersion(String v) => _libraryVersion = v;

  @override
  Stream<NativeAlertEvent> get alertStream => _alertCtrl.stream;

  @override
  Stream<Map<int, NativeTorrentStatus>> get statusStream => _statusCtrl.stream;

  /// Emit an alert into the alert stream.
  void emitAlert(NativeAlertEvent alert) {
    if (!_alertCtrl.isClosed) {
      _alertCtrl.add(alert);
    }
  }

  /// Emit a batch or map of statuses.
  void emitStatuses(Map<int, NativeTorrentStatus> statuses) {
    _statuses.addAll(statuses);
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(Map.unmodifiable(_statuses));
    }
  }

  /// Seed initial files and status for a test torrent.
  void seedTorrent({
    required int id,
    required String name,
    required List<NativeFileInfo> files,
    int downloadRate = 1024 * 1024,
    int uploadRate = 0,
    int numPeers = 5,
    int numSeeds = 2,
    bool hasMetadata = true,
  }) {
    _files[id] = List.from(files);
    _filePriorities[id] = List.filled(files.length, 4);
    _fileProgress[id] = List.filled(files.length, 0);

    final totalSize = files.fold<int>(0, (sum, f) => sum + f.size);
    final status = NativeTorrentStatus(
      id: id,
      name: name,
      savePath: '/downloads/',
      errorMsg: '',
      state: 2, // downloading
      stateLabel: 'Downloading',
      progress: 0.0,
      downloadRate: downloadRate,
      uploadRate: uploadRate,
      totalDone: 0,
      totalWanted: totalSize,
      totalWantedDone: 0,
      totalUploaded: 0,
      numPeers: numPeers,
      numSeeds: numSeeds,
      numPieces: 100,
      piecesDone: 0,
      pieces: List.filled(100, false),
      isPaused: false,
      isFinished: false,
      hasMetadata: hasMetadata,
      queuePosition: 0,
      fileProgress: _fileProgress[id]!,
      filePriorities: _filePriorities[id]!,
    );

    _statuses[id] = status;
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(Map.unmodifiable(_statuses));
    }
  }

  /// Simulate progress advancing for a torrent.
  void simulateProgress({
    required int id,
    required List<int> perFileDownloadedBytes,
  }) {
    final status = _statuses[id];
    final files = _files[id];
    final priorities = _filePriorities[id];
    if (status == null || files == null || priorities == null) return;

    _fileProgress[id] = List.from(perFileDownloadedBytes);

    var wantedTotal = 0;
    var wantedDone = 0;
    var allDone = 0;

    for (var i = 0; i < files.length; i++) {
      final downloaded = i < perFileDownloadedBytes.length ? perFileDownloadedBytes[i] : 0;
      allDone += downloaded;
      if (priorities[i] > 0) {
        wantedTotal += files[i].size;
        wantedDone += downloaded;
      }
    }

    final progress = wantedTotal > 0 ? (wantedDone / wantedTotal).clamp(0.0, 1.0) : 1.0;
    final totalPieces = status.numPieces > 0 ? status.numPieces : 100;
    final piecesDone = (totalPieces * progress).floor();
    final piecesBitfield = List.generate(totalPieces, (i) => i < piecesDone);

    final updated = status.copyWith(
      progress: progress,
      totalDone: allDone,
      totalWanted: wantedTotal,
      totalWantedDone: wantedDone,
      piecesDone: piecesDone,
      pieces: piecesBitfield,
      fileProgress: _fileProgress[id],
      filePriorities: priorities,
      isFinished: progress >= 0.999,
      state: progress >= 0.999 ? 3 : 2,
      stateLabel: progress >= 0.999 ? 'Finished' : 'Downloading',
    );

    _statuses[id] = updated;
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(Map.unmodifiable(_statuses));
    }
  }

  @override
  Future<void> init({
    String listenInterface = '',
    int downloadLimit = 0,
    int uploadLimit = 0,
    Duration pollInterval = const Duration(milliseconds: 600),
    bool fetchTrackers = true,
    String? defaultSavePath,
  }) async {
    _initialized = true;
  }

  @override
  Future<void> dispose() async {
    // FIX(N3): Close controllers and clear all internal state
    _initialized = false;
    _statuses.clear();
    _files.clear();
    _filePriorities.clear();
    _fileProgress.clear();
    _trackers.clear();
    _webSeeds.clear();
    _sequential.clear();
    _superSeeding.clear();
    _savedResumeData.clear();
    if (!_alertCtrl.isClosed) {
      await _alertCtrl.close();
    }
    if (!_statusCtrl.isClosed) {
      await _statusCtrl.close();
    }
  }

  @override
  int addMagnet(String magnetUri, String savePath,
      {bool streamOnly = false, List<int>? resumeData}) {
    // FIX(N3): Monotonic ID assignment
    final id = _nextId++;
    if (resumeData != null && resumeData.isNotEmpty) {
      _savedResumeData[id] = List.from(resumeData);
    }
    final status = NativeTorrentStatus(
      id: id,
      name: 'Magnet_',
      savePath: savePath,
      errorMsg: '',
      state: 1, // getting metadata
      stateLabel: 'Getting metadata',
      progress: 0.0,
      downloadRate: 0,
      uploadRate: 0,
      totalDone: 0,
      totalWanted: 0,
      totalWantedDone: 0,
      totalUploaded: 0,
      numPeers: 0,
      numSeeds: 0,
      isPaused: false,
      isFinished: false,
      hasMetadata: false,
      queuePosition: 0,
    );
    _statuses[id] = status;
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(Map.unmodifiable(_statuses));
    }
    return id;
  }

  @override
  int addTorrentFile(String filePath, String savePath, {bool streamOnly = false}) {
    // FIX(N3): Monotonic ID assignment
    final id = _nextId++;
    final status = NativeTorrentStatus(
      id: id,
      name: filePath.split('/').last,
      savePath: savePath,
      errorMsg: '',
      state: 0, // checking
      stateLabel: 'Checking files',
      progress: 0.0,
      downloadRate: 0,
      uploadRate: 0,
      totalDone: 0,
      totalWanted: 0,
      totalWantedDone: 0,
      totalUploaded: 0,
      numPeers: 0,
      numSeeds: 0,
      isPaused: false,
      isFinished: false,
      hasMetadata: true,
      queuePosition: 0,
    );
    _statuses[id] = status;
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(Map.unmodifiable(_statuses));
    }
    return id;
  }

  @override
  void removeTorrent(int id, {bool deleteFiles = false}) {
    // FIX(N3): Clear all associated trackers, webSeeds, resumeData, priorities, and state
    _statuses.remove(id);
    _files.remove(id);
    _filePriorities.remove(id);
    _fileProgress.remove(id);
    _trackers.remove(id);
    _webSeeds.remove(id);
    _savedResumeData.remove(id);
    _sequential.remove(id);
    _superSeeding.remove(id);
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(Map.unmodifiable(_statuses));
    }
  }

  @override
  Future<void> pauseTorrent(int id, {bool graceful = true}) async {
    final status = _statuses[id];
    if (status == null) return;

    if (graceful && !simulateGracefulPauseTimeout) {
      try {
        final resumeData =
            await saveResumeData(id, timeout: const Duration(seconds: 5));
        if (resumeData == null) {
          _recordTelemetry('resume_data_missing', taskId: '');
        }
      } catch (_) {
        _recordTelemetry('resume_data_missing', taskId: '');
      }
      if (gracefulPauseDelay > Duration.zero) {
        await Future.delayed(gracefulPauseDelay);
      }
      // Emit stopped announce alert first
      emitAlert(NativeAlertEvent(
        type: TorrentAlertType.stoppedAnnounce,
        alertCode: 45,
        torrentId: id,
        message: 'Stopped announce completed',
        timestamp: DateTime.now(),
      ));

      // Emit torrent paused alert
      emitAlert(NativeAlertEvent(
        type: TorrentAlertType.torrentPaused,
        alertCode: 34,
        torrentId: id,
        message: 'Torrent paused gracefully',
        timestamp: DateTime.now(),
      ));
    } else if (graceful && simulateGracefulPauseTimeout) {
      _recordTelemetry('resume_data_missing', taskId: '');
    }

    if (!simulateGracefulPauseTimeout) {
      _statuses[id] = status.copyWith(
        isPaused: true,
        stateLabel: 'Paused',
        downloadRate: 0,
        uploadRate: 0,
      );
      if (!_statusCtrl.isClosed) {
        _statusCtrl.add(Map.unmodifiable(_statuses));
      }
    }
  }

  @override
  Future<void> resumeTorrent(int id) async {
    final status = _statuses[id];
    if (status == null) return;

    _statuses[id] = status.copyWith(
      isPaused: false,
      stateLabel: 'Downloading',
      downloadRate: 500 * 1024,
      uploadRate: 0,
    );
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(Map.unmodifiable(_statuses));
    }

    emitAlert(NativeAlertEvent(
      type: TorrentAlertType.torrentResumed,
      alertCode: 35,
      torrentId: id,
      message: 'Torrent resumed',
      timestamp: DateTime.now(),
    ));
  }

  @override
  void recheckTorrent(int id) {
    final status = _statuses[id];
    if (status == null) return;

    _statuses[id] = status.copyWith(
      state: 0,
      stateLabel: 'Checking files',
      progress: 0.0,
      totalWantedDone: 0,
      piecesDone: 0,
      pieces: List.filled(status.numPieces, false),
    );
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(Map.unmodifiable(_statuses));
    }
  }

  @override
  NativeTorrentStatus? getTorrentStatus(int id) => _statuses[id];

  @override
  Map<int, NativeTorrentStatus> getAllTorrentStatuses() =>
      Map.unmodifiable(_statuses);

  @override
  List<NativeFileInfo> getFiles(int id) =>
      List.unmodifiable(_files[id] ?? const []);

  @override
  void setFilePriorities(int id, List<int> priorities) {
    _filePriorities[id] = List.from(priorities);
    final files = _files[id];
    final status = _statuses[id];
    final curProgress = _fileProgress[id] ?? [];

    if (files != null && status != null) {
      var newWantedTotal = 0;
      var newWantedDone = 0;

      for (var i = 0; i < files.length; i++) {
        final p = i < priorities.length ? priorities[i] : 4;
        final done = i < curProgress.length ? curProgress[i] : 0;
        if (p > 0) {
          newWantedTotal += files[i].size;
          newWantedDone += done;
        }
      }

      final progress = newWantedTotal > 0
          ? (newWantedDone / newWantedTotal).clamp(0.0, 1.0)
          : 1.0;

      _statuses[id] = status.copyWith(
        totalWanted: newWantedTotal,
        totalWantedDone: newWantedDone,
        progress: progress,
        filePriorities: priorities,
      );
      if (!_statusCtrl.isClosed) {
        _statusCtrl.add(Map.unmodifiable(_statuses));
      }
    }
  }

  @override
  List<int> getFilePriorities(int id) =>
      List.unmodifiable(_filePriorities[id] ?? const []);

  @override
  List<int> getFileProgress(int id) =>
      List.unmodifiable(_fileProgress[id] ?? const []);

  int saveResumeDataCallCount = 0;

  @override
  Future<List<int>?> saveResumeData(
    int id, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    saveResumeDataCallCount++;
    final data = [0x64, 0x31, 0x30, 0x3a, 0x66, 0x61, 0x73, 0x74, 0x65]; // bencoded blob
    _savedResumeData[id] = data;

    emitAlert(NativeAlertEvent(
      type: TorrentAlertType.saveResumeDataCompleted,
      alertCode: 30,
      torrentId: id,
      message: 'Fastresume saved',
      timestamp: DateTime.now(),
      resumeData: data,
    ));

    return data;
  }

  // FIX(N3): simulateResumeLoadFailure knob
  @override
  bool loadResumeData(int id, List<int> data) {
    if (simulateResumeLoadFailure) return false;
    _savedResumeData[id] = List.from(data);
    return true;
  }

  @override
  void setDownloadLimit(int bps) {}

  @override
  void setUploadLimit(int bps) {}

  @override
  void configureSession(NativeBtConfig config) {}

  @override
  NativeBtConfig getDefaultConfig() => const NativeBtConfig();

  @override
  List<NativeTrackerInfo> getTrackers(int id) =>
      List.unmodifiable(_trackers[id] ?? const []);

  @override
  void addTracker(int id, String trackerUrl, {int tier = 0}) {
    final list = _trackers.putIfAbsent(id, () => []);
    list.add(NativeTrackerInfo(
      url: trackerUrl,
      tier: tier,
      status: 'working',
      seeds: 0,
      peers: 0,
      message: '',
    ));
  }

  @override
  void removeTracker(int id, String trackerUrl) {
    _trackers[id]?.removeWhere((t) => t.url == trackerUrl);
  }

  @override
  void announceNow(int id) {}

  @override
  void setSequentialDownload(int id, bool enabled) {
    if (enabled) {
      _sequential.add(id);
    } else {
      _sequential.remove(id);
    }
  }

  @override
  void setSuperSeeding(int id, bool enabled) {
    if (enabled) {
      _superSeeding.add(id);
    } else {
      _superSeeding.remove(id);
    }
  }

  @override
  void setPieceDeadline(int id, int pieceIndex, int deadlineMs) {}

  @override
  Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  }) async {
    return outputPath;
  }

  @override
  Future<bool> loadIpFilter(String filePath) async => true;

  @override
  Future<void> setProxy({
    required String host,
    required int port,
    required int type,
    String? username,
    String? password,
  }) async {}

  @override
  Future<void> setSslCertificate({
    required String certPath,
    required String privateKeyPath,
    String? dhParamsPath,
  }) async {}

  @override
  void addWebSeed(int id, String url) {
    final list = _webSeeds.putIfAbsent(id, () => []);
    if (!list.contains(url)) list.add(url);
  }

  @override
  void removeWebSeed(int id, String url) {
    _webSeeds[id]?.remove(url);
  }

  @override
  List<String> getWebSeeds(int id) =>
      List.unmodifiable(_webSeeds[id] ?? const []);
}
