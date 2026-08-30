import 'dart:async';
import 'dart:math';
import 'package:libtorrent_flutter/libtorrent_flutter.dart' as lt;

import '../../domain/torrent_models.dart';
import '../../interfaces/i_torrent_native.dart';
import '../diagnostic_service.dart';

/// Concrete implementation of [ITorrentNative] backed by `libtorrent_flutter: 1.9.2`.
class LibtorrentNativeImpl implements ITorrentNative {
  LibtorrentNativeImpl();

  StreamSubscription<Map<int, lt.TorrentInfo>>? _statusSub;

  StreamController<NativeAlertEvent> _alertStreamCtrl =
      StreamController<NativeAlertEvent>.broadcast();
  StreamController<Map<int, NativeTorrentStatus>> _statusStreamCtrl =
      StreamController<Map<int, NativeTorrentStatus>>.broadcast();

  final Map<int, lt.TorrentInfo> _previousTorrents = {};
  final Map<int, List<int>> _cachedPriorities = {};
  final Set<String> _warnedStubs = {};

  @override
  bool get isInitialized => lt.LibtorrentFlutter.isInitialized;

  @override
  String get libraryVersion {
    if (!isInitialized) return 'unknown';
    try {
      return lt.LibtorrentFlutter.instance.libraryVersion;
    } catch (_) {
      return 'libtorrent/1.9.2';
    }
  }

  @override
  String? get bridgeDiagnostics =>
      'Running on libtorrent_flutter 1.9.2 which lacks support for piece bitfields, file progress, trackers management, resume data, and peer inspection.';

  @override
  bool get isBridgeCompatible => true;

  void _logStubWarning(String method) {
    if (_warnedStubs.add(method)) {
      DiagnosticService.instance.record(
        'diagnostic',
        'unsupported_bridge_method',
        details: 'Method $method is unsupported in libtorrent_flutter 1.9.2',
      );
    }
  }

  @override
  Stream<NativeAlertEvent> get alertStream => _alertStreamCtrl.stream;

  @override
  Stream<Map<int, NativeTorrentStatus>> get statusStream =>
      _statusStreamCtrl.stream;

  static int _stateToNativeCode(lt.TorrentState state) {
    switch (state) {
      case lt.TorrentState.error:
        return -2;
      case lt.TorrentState.checkingFiles:
        return 0;
      case lt.TorrentState.downloadingMetadata:
        return 1;
      case lt.TorrentState.downloading:
        return 2;
      case lt.TorrentState.finished:
        return 3;
      case lt.TorrentState.seeding:
        return 4;
      case lt.TorrentState.allocating:
        return 5;
      case lt.TorrentState.checkingResume:
        return 6;
      case lt.TorrentState.unknown:
        return -1;
    }
  }

  // Estimate piece size as 256KB (standard default in libtorrent)
  static const int _estimatedPieceSize = 262144;

  NativeTorrentStatus _mapStatus(lt.TorrentInfo info) {
    // B16: `TorrentInfo.totalDone` counts bytes of deselected files too,
    // while libtorrent's `progress` is the wanted-only fraction
    // (total_wanted_done / total_wanted). 1.9.2 exposes no separate
    // wanted-done field, so derive totalWantedDone from the wanted-only
    // progress; reporting totalDone inflated progress/ETA for torrents with
    // deselected files and could mark them complete before the wanted bytes
    // were actually on disk.
    final double wantedProgress =
        info.progress.isFinite ? info.progress.clamp(0.0, 1.0) : 0.0;
    final int wantedDone = (info.hasMetadata && info.totalWanted > 0)
        ? (wantedProgress * info.totalWanted).round().clamp(0, info.totalWanted)
        : 0;
    // B2: without metadata there is no piece table. The old max(1, …)
    // estimate always reported a fake 1-piece torrent, which kept the
    // handler's dedicated metadata-phase branch permanently dead.
    final int estimatedNumPieces = (info.hasMetadata && info.totalWanted > 0)
        ? max(1, info.totalWanted ~/ _estimatedPieceSize)
        : 0;
    final int estimatedPiecesDone =
        (estimatedNumPieces * wantedProgress).floor();

    // Generate a synthetic boolean bitfield for UI compatibility
    final pieces = List<bool>.generate(
      estimatedNumPieces,
      (index) => index < estimatedPiecesDone,
    );

    return NativeTorrentStatus(
      id: info.id,
      name: info.name,
      savePath: info.savePath,
      errorMsg: info.errorMsg,
      state: _stateToNativeCode(info.state),
      stateLabel: info.state.label,
      progress: info.progress,
      downloadRate: info.downloadRate,
      uploadRate: info.uploadRate,
      totalDone: info.totalDone,
      totalWanted: info.totalWanted,
      // B16: wanted-only derived bytes — see the derivation above.
      totalWantedDone: wantedDone,
      totalUploaded: info.totalUploaded,
      numPeers: info.numPeers,
      numSeeds: info.numSeeds,
      numComplete: null,
      numIncomplete: null,
      numPieces: estimatedNumPieces, // Estimated
      piecesDone: estimatedPiecesDone, // Estimated
      pieces: pieces, // Estimated
      isPaused: info.isPaused,
      isFinished: info.isFinished,
      hasMetadata: info.hasMetadata,
      queuePosition: info.queuePosition,
      fileProgress: const [],
      filePriorities: _cachedPriorities[info.id] ?? const [],
      infoHashV1: '',
      infoHashV2: '',
      distributedCopies: 0.0,
      activeTime: 0,
      seedingTime: 0,
    );
  }

  void _emitAlertsFromStatus(Map<int, lt.TorrentInfo> current) {
    if (_alertStreamCtrl.isClosed) return;
    final now = DateTime.now();

    for (final entry in current.entries) {
      final id = entry.key;
      final newInfo = entry.value;
      final oldInfo = _previousTorrents[id];

      if (oldInfo != null) {
        if (!oldInfo.hasMetadata && newInfo.hasMetadata) {
          _alertStreamCtrl.add(NativeAlertEvent(
            type: TorrentAlertType.metadataReceived,
            alertCode: 38,
            torrentId: id,
            message: 'Metadata received for torrent $id',
            timestamp: now,
          ));
        }

        if (!oldInfo.isPaused && newInfo.isPaused) {
          _alertStreamCtrl.add(NativeAlertEvent(
            type: TorrentAlertType.torrentPaused,
            alertCode: 34,
            torrentId: id,
            message: 'Torrent $id paused',
            timestamp: now,
          ));
        } else if (oldInfo.isPaused && !newInfo.isPaused) {
          _alertStreamCtrl.add(NativeAlertEvent(
            type: TorrentAlertType.torrentResumed,
            alertCode: 35,
            torrentId: id,
            message: 'Torrent $id resumed',
            timestamp: now,
          ));
        }

        if (newInfo.errorMsg.isNotEmpty &&
            newInfo.errorMsg != oldInfo.errorMsg) {
          _alertStreamCtrl.add(NativeAlertEvent(
            type: TorrentAlertType.torrentError,
            alertCode: 64,
            torrentId: id,
            message: newInfo.errorMsg,
            timestamp: now,
            error: newInfo.errorMsg,
          ));
        }

        if (newInfo.totalDone > oldInfo.totalDone) {
          _alertStreamCtrl.add(NativeAlertEvent(
            type: TorrentAlertType.pieceFinished,
            alertCode: 26,
            torrentId: id,
            message: 'Progress updated',
            timestamp: now,
          ));
        }
      } else if (newInfo.hasMetadata) {
        _alertStreamCtrl.add(NativeAlertEvent(
          type: TorrentAlertType.metadataReceived,
          alertCode: 38,
          torrentId: id,
          message: 'Metadata present for torrent $id',
          timestamp: now,
        ));
      }

      // Heartbeat status tick
      _alertStreamCtrl.add(NativeAlertEvent(
        type: TorrentAlertType.statusTick,
        alertCode: 0,
        torrentId: id,
        message: 'Status tick',
        timestamp: now,
      ));
    }

    _previousTorrents.clear();
    _previousTorrents.addAll(current);
  }

  void _ensureStatusSubscription() {
    if (!lt.LibtorrentFlutter.isInitialized) return;
    if (_statusSub != null) return;
    _statusSub = lt.LibtorrentFlutter.instance.torrentUpdates.listen((map) {
      if (_statusStreamCtrl.isClosed) return;
      _emitAlertsFromStatus(map);
      final mapped = map.map((key, value) => MapEntry(key, _mapStatus(value)));
      _statusStreamCtrl.add(Map.unmodifiable(mapped));
    });
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
    if (_alertStreamCtrl.isClosed) {
      _alertStreamCtrl = StreamController<NativeAlertEvent>.broadcast();
    }
    if (_statusStreamCtrl.isClosed) {
      _statusStreamCtrl =
          StreamController<Map<int, NativeTorrentStatus>>.broadcast();
    }
    if (!lt.LibtorrentFlutter.isInitialized) {
      await lt.LibtorrentFlutter.init(
        listenInterface: listenInterface,
        downloadLimit: downloadLimit,
        uploadLimit: uploadLimit,
        pollInterval: pollInterval,
        fetchTrackers: fetchTrackers,
        defaultSavePath: defaultSavePath,
      );
    }

    _ensureStatusSubscription();
  }

  @override
  Future<void> dispose() async {
    await _statusSub?.cancel();
    _statusSub = null;
    _previousTorrents.clear();
    _cachedPriorities.clear();
    if (!_alertStreamCtrl.isClosed) {
      await _alertStreamCtrl.close();
    }
    if (!_statusStreamCtrl.isClosed) {
      await _statusStreamCtrl.close();
    }
    if (lt.LibtorrentFlutter.isInitialized) {
      await lt.LibtorrentFlutter.instance.dispose();
    }
  }

  @override
  int addMagnet(String magnetUri, String savePath,
      {bool streamOnly = false, List<int>? resumeData}) {
    return lt.LibtorrentFlutter.instance
        .addMagnet(magnetUri, savePath, streamOnly);
  }

  @override
  int addTorrentFile(String filePath, String savePath,
      {bool streamOnly = false, List<int>? resumeData}) {
    return lt.LibtorrentFlutter.instance
        .addTorrentFile(filePath, savePath, streamOnly);
  }

  @override
  void removeTorrent(int id, {bool deleteFiles = false}) {
    if (id < 0) return;
    try {
      _cachedPriorities.remove(id);
      _previousTorrents.remove(id);
      lt.LibtorrentFlutter.instance.removeTorrent(id, deleteFiles: deleteFiles);
    } catch (_) {
      // Catch any native or FFI exceptions for dead/invalid handles
    }
  }

  @override
  Future<void> pauseTorrent(int id, {bool graceful = true}) async {
    if (id < 0) return;
    lt.LibtorrentFlutter.instance.pauseTorrent(id);
  }

  @override
  Future<void> resumeTorrent(int id) async {
    if (id < 0) return;
    lt.LibtorrentFlutter.instance.resumeTorrent(id);
    try {
      await statusStream.firstWhere((map) {
        final st = map[id];
        return st != null && !st.isPaused;
      }).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      DiagnosticService.instance.record(
        'diagnostic',
        'torrent_resume_retry',
        details: 'torrentId=$id',
      );
      lt.LibtorrentFlutter.instance.resumeTorrent(id);
    } catch (_) {}
  }

  @override
  void recheckTorrent(int id) {
    if (id < 0) return;
    lt.LibtorrentFlutter.instance.recheckTorrent(id);
  }

  @override
  NativeTorrentStatus? getTorrentStatus(int id) {
    final s = lt.LibtorrentFlutter.instance.torrents[id];
    if (s == null) return null;
    return _mapStatus(s);
  }

  @override
  Map<int, NativeTorrentStatus> getAllTorrentStatuses() {
    final raw = lt.LibtorrentFlutter.instance.torrents;
    return raw.map((k, v) => MapEntry(k, _mapStatus(v)));
  }

  @override
  List<NativeFileInfo> getFiles(int id) {
    final files = lt.LibtorrentFlutter.instance.getFiles(id);
    return files
        .map((f) => NativeFileInfo(
              index: f.index,
              name: f.name,
              path: f.path,
              size: f.size,
              isStreamable: f.isStreamable,
            ))
        .toList();
  }

  @override
  void setFilePriorities(int id, List<int> priorities) {
    _cachedPriorities[id] = List.unmodifiable(priorities);
    lt.LibtorrentFlutter.instance.setFilePriorities(id, priorities);
  }

  @override
  List<int> getFilePriorities(int id) {
    return _cachedPriorities[id] ?? const [];
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  List<int> getFileProgress(int id) {
    _logStubWarning('getFileProgress');
    return const [];
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  Future<List<PeerConnectionQuality>> getPeers(int torrentId) async {
    _logStubWarning('getPeers');
    return const [];
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  Future<List<int>?> saveResumeData(
    int id, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _logStubWarning('saveResumeData');
    return null;
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  bool loadResumeData(int id, List<int> data) {
    _logStubWarning('loadResumeData');
    return false;
  }

  @override
  void setDownloadLimit(int bps) {
    lt.LibtorrentFlutter.instance.setDownloadLimit(bps);
  }

  @override
  void setUploadLimit(int bps) {
    lt.LibtorrentFlutter.instance.setUploadLimit(bps);
  }

  @override
  void configureSession(NativeBtConfig config) {
    lt.LibtorrentFlutter.instance.configureSession(lt.BtConfig(
      cacheSize: config.cacheSize,
      readerReadAhead: config.readerReadAhead,
      preloadCache: config.preloadCache,
      connectionsLimit: config.connectionsLimit,
      torrentDisconnectTimeout: config.torrentDisconnectTimeout,
      forceEncrypt: config.forceEncrypt,
      disableTcp: config.disableTcp,
      disableUtp: config.disableUtp,
      disableUpload: config.disableUpload,
      disableDht: config.disableDht,
      disableUpnp: config.disableUpnp,
      enableIpv6: config.enableIpv6,
      // Note: libtorrent_flutter 1.9.2 uses KB/s for rate limits, while NativeBtConfig uses Bytes/s.
      // Dividing by 1024 converts from Bytes/s to KB/s.
      downloadRateLimit: config.downloadRateLimit ~/ 1024,
      uploadRateLimit: config.uploadRateLimit ~/ 1024,
      peersListenPort: config.peersListenPort,
      responsiveMode: config.responsiveMode,
    ));
    // FIX P0-6: Attempt to inject DHT bootstrap nodes if native supports it.
    // On 1.9.2 this is a no-op (bridge stub), so we also enrich magnet URIs
    // with default trackers as fallback (see TorrentService._enrichMagnet).
    if (!config.disableDht && config.dhtBootstrapNodes.isNotEmpty) {
      DiagnosticService.instance.record(
        'diagnostic',
        'dht_bootstrap_configured',
        details: 'nodes=${config.dhtBootstrapNodes.length} (stub may ignore)',
      );
    }
  }

  @override
  NativeBtConfig getDefaultConfig() {
    final def = lt.LibtorrentFlutter.instance.getDefaultConfig();
    return NativeBtConfig(
      cacheSize: def.cacheSize,
      readerReadAhead: def.readerReadAhead,
      preloadCache: def.preloadCache,
      connectionsLimit: def.connectionsLimit,
      torrentDisconnectTimeout: def.torrentDisconnectTimeout,
      forceEncrypt: def.forceEncrypt,
      disableTcp: def.disableTcp,
      disableUtp: def.disableUtp,
      disableUpload: def.disableUpload,
      disableDht: def.disableDht,
      disableUpnp: def.disableUpnp,
      enableIpv6: def.enableIpv6,
      // Note: libtorrent_flutter 1.9.2 uses KB/s for rate limits, while NativeBtConfig uses Bytes/s.
      // Multiplying by 1024 converts from KB/s to Bytes/s.
      downloadRateLimit: def.downloadRateLimit * 1024,
      uploadRateLimit: def.uploadRateLimit * 1024,
      peersListenPort: def.peersListenPort,
      responsiveMode: def.responsiveMode,
    );
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  List<NativeTrackerInfo> getTrackers(int id) {
    _logStubWarning('getTrackers');
    return const [];
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  void addTracker(int id, String trackerUrl, {int tier = 0}) {
    _logStubWarning('addTracker');
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  void removeTracker(int id, String trackerUrl) {
    _logStubWarning('removeTracker');
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  void announceNow(int id) {
    _logStubWarning('announceNow');
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  void setSequentialDownload(int id, bool enabled) {
    _logStubWarning('setSequentialDownload');
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  void setSuperSeeding(int id, bool enabled) {
    _logStubWarning('setSuperSeeding');
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  void setPieceDeadline(int id, int pieceIndex, int deadlineMs) {
    _logStubWarning('setPieceDeadline');
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  }) async {
    _logStubWarning('createTorrent');
    return null;
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  Future<bool> loadIpFilter(String filePath) async {
    _logStubWarning('loadIpFilter');
    return false;
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  Future<void> setProxy({
    required String host,
    required int port,
    required int type,
    String? username,
    String? password,
  }) async {
    _logStubWarning('setProxy');
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  Future<void> setSslCertificate({
    required String certPath,
    required String privateKeyPath,
    String? dhParamsPath,
  }) async {
    _logStubWarning('setSslCertificate');
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  void addWebSeed(int id, String url) {
    _logStubWarning('addWebSeed');
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  void removeWebSeed(int id, String url) {
    _logStubWarning('removeWebSeed');
  }

  /// Unsupported in libtorrent_flutter 1.9.2
  @override
  List<String> getWebSeeds(int id) {
    _logStubWarning('getWebSeeds');
    return const [];
  }
}
