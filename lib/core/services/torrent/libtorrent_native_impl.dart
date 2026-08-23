import 'dart:async';
import 'package:libtorrent_flutter/libtorrent_flutter.dart' as lt;

import '../../domain/torrent_models.dart';
import '../../interfaces/i_torrent_native.dart';
import '../diagnostic_service.dart';

/// Concrete implementation of [ITorrentNative] backed by the vendored `libtorrent_flutter`.
class LibtorrentNativeImpl implements ITorrentNative {
  LibtorrentNativeImpl();

  StreamSubscription<lt.LtAlert>? _alertSub;
  StreamSubscription<Map<int, lt.TorrentInfo>>? _statusSub;

  StreamController<NativeAlertEvent> _alertStreamCtrl =
      StreamController<NativeAlertEvent>.broadcast();
  StreamController<Map<int, NativeTorrentStatus>> _statusStreamCtrl =
      StreamController<Map<int, NativeTorrentStatus>>.broadcast();

  @override
  bool get isInitialized => lt.LibtorrentFlutter.isInitialized;

  @override
  String get libraryVersion {
    if (!isInitialized) return 'unknown';
    try {
      return lt.LibtorrentFlutter.instance.libraryVersion;
    } catch (_) {
      return 'libtorrent/2.0';
    }
  }

  @override
  String? get bridgeDiagnostics {
    try {
      return lt.LibtorrentFlutter.abiReport?.describe();
    } catch (_) {
      return null;
    }
  }

  @override
  bool get isBridgeCompatible {
    try {
      // No report yet (not initialized) is not evidence of a mismatch.
      return lt.LibtorrentFlutter.abiReport?.isCompatible ?? true;
    } catch (_) {
      return true;
    }
  }

  // FIX(N1): statusStream backed by broadcast StreamController
  @override
  Stream<NativeAlertEvent> get alertStream => _alertStreamCtrl.stream;

  @override
  Stream<Map<int, NativeTorrentStatus>> get statusStream =>
      _statusStreamCtrl.stream;

  NativeTorrentStatus _mapStatus(lt.TorrentInfo info) {
    return NativeTorrentStatus(
      id: info.id,
      name: info.name,
      savePath: info.savePath,
      errorMsg: info.errorMsg,
      state: info.state.nativeCode,
      stateLabel: info.state.label,
      progress: info.progress,
      downloadRate: info.downloadRate,
      uploadRate: info.uploadRate,
      totalDone: info.totalDone,
      totalWanted: info.totalWanted,
      totalWantedDone: info.totalWantedDone,
      totalUploaded: info.totalUploaded,
      numPeers: info.numPeers,
      numSeeds: info.numSeeds,
      numComplete: info.numComplete,
      numIncomplete: info.numIncomplete,
      numPieces: info.numPieces,
      piecesDone: info.piecesDone,
      pieces: info.pieces,
      isPaused: info.isPaused,
      isFinished: info.isFinished,
      hasMetadata: info.hasMetadata,
      queuePosition: info.queuePosition,
      fileProgress: info.fileProgress,
      filePriorities: info.filePriorities,
      // FIX: [Audit] Map missing FFI fields
      infoHashV1: '',
      infoHashV2: '',
      distributedCopies: 0.0,
      activeTime: 0,
      seedingTime: 0,
    );
  }

  // FIX(N2): Idempotent subscription establishment
  void _ensureAlertSubscription() {
    if (!lt.LibtorrentFlutter.isInitialized) return;
    if (_alertSub != null) return;
    _alertSub = lt.LibtorrentFlutter.instance.alertUpdates.listen((alert) {
      if (_alertStreamCtrl.isClosed) return;
      final alertType = TorrentAlertType.fromNativeType(alert.type);
      _alertStreamCtrl.add(NativeAlertEvent(
        type: alertType,
        alertCode: alert.type,
        torrentId: alert.torrentId,
        message: alert.message,
        timestamp: alert.timestamp,
        resumeData: alert.data,
        pieceIndex: alert.pieceIndex,
        trackerUrl: alert.trackerUrl,
        error: alert.error,
      ));
    });
  }

  void _ensureStatusSubscription() {
    if (!lt.LibtorrentFlutter.isInitialized) return;
    if (_statusSub != null) return;
    _statusSub = lt.LibtorrentFlutter.instance.torrentUpdates.listen((map) {
      if (_statusStreamCtrl.isClosed) return;
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
    // The adapter can be reused after a full engine dispose. Its controllers
    // are intentionally closed during dispose, so recreate them before
    // subscribing to the next native session.
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

    // FIX(N2): Always ensure subscriptions are active even on re-init / early-return
    _ensureAlertSubscription();
    _ensureStatusSubscription();
  }

  @override
  Future<void> dispose() async {
    // FIX(N1): Cancel subscriptions and close controllers
    await _alertSub?.cancel();
    _alertSub = null;
    await _statusSub?.cancel();
    _statusSub = null;
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
        .addMagnet(magnetUri, savePath, streamOnly, resumeData);
  }

  @override
  int addTorrentFile(String filePath, String savePath,
      {bool streamOnly = false, List<int>? resumeData}) {
    return lt.LibtorrentFlutter.instance
        .addTorrentFile(filePath, savePath, streamOnly, resumeData);
  }

  @override
  void removeTorrent(int id, {bool deleteFiles = false}) {
    if (id < 0) return;
    try {
      lt.LibtorrentFlutter.instance.removeTorrent(id, deleteFiles: deleteFiles);
    } catch (e) {
      // Catch any native or FFI exceptions for dead/invalid handles
    }
  }

  @override
  Future<void> pauseTorrent(int id, {bool graceful = true}) async {
    // A graceful pause flushes resume data first, which means waiting for a
    // save_resume_data alert. When the binary has no lt_save_resume_data export
    // that alert never arrives, so this block used to burn its full 5s timeout,
    // report the pause unconfirmed, and hand the caller a force-stop — tearing
    // down every peer connection and restarting the handshake from scratch on
    // the next resume. Skip straight to the pause when resume data is
    // unavailable: there is nothing to flush.
    if (graceful && lt.LibtorrentFlutter.supportsResumeData) {
      try {
        final alertFuture = alertStream
            .firstWhere(
              (a) =>
                  a.torrentId == id &&
                  (a.type == TorrentAlertType.saveResumeDataCompleted ||
                      a.type == TorrentAlertType.saveResumeDataFailed),
            )
            .timeout(const Duration(seconds: 5));
        await saveResumeData(id, timeout: const Duration(seconds: 5));
        final alert = await alertFuture;
        if (alert.type == TorrentAlertType.saveResumeDataFailed) {
          DiagnosticService.instance
              .recordTelemetryAlert('resume_data_missing', taskId: '$id');
        }
      } catch (_) {
        DiagnosticService.instance
            .recordTelemetryAlert('resume_data_missing', taskId: '$id');
      }
    }
    lt.LibtorrentFlutter.instance.pauseTorrent(id, graceful: graceful);
  }

  @override
  Future<void> resumeTorrent(int id) async {
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
    lt.LibtorrentFlutter.instance.recheckTorrent(id);
  }

  @override
  NativeTorrentStatus? getTorrentStatus(int id) {
    final s = lt.LibtorrentFlutter.instance.getTorrentStatus(id);
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
    lt.LibtorrentFlutter.instance.setFilePriorities(id, priorities);
  }

  @override
  List<int> getFilePriorities(int id) {
    return lt.LibtorrentFlutter.instance.getFilePriorities(id);
  }

  @override
  List<int> getFileProgress(int id) {
    return lt.LibtorrentFlutter.instance.getFileProgress(id);
  }

  /// Per-peer enumeration is not available on this backend.
  ///
  /// libtorrent's `torrent_handle::get_peer_info` is not exported by the C++
  /// bridge (there is no `lt_get_peer_info` symbol), so there is nothing to
  /// read: the FFI status struct carries only aggregate swarm counts
  /// (`numSeeds` / `numPeers` / `numComplete` / `numIncomplete`), which callers
  /// consume through the status stream instead. Returning an empty list here is
  /// the honest answer — synthesising placeholder rows from the aggregate counts
  /// would put fabricated addresses and speeds in front of the user.
  @override
  Future<List<PeerConnectionQuality>> getPeers(int torrentId) async {
    return const [];
  }

  @override
  Future<List<int>?> saveResumeData(
    int id, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    return lt.LibtorrentFlutter.instance.saveResumeData(id, timeout: timeout);
  }

  @override
  bool loadResumeData(int id, List<int> data) {
    return lt.LibtorrentFlutter.instance.loadResumeData(id, data);
  }

  @override
  void setDownloadLimit(int bps) {
    lt.LibtorrentFlutter.instance.setDownloadLimit(bps);
  }

  @override
  void setUploadLimit(int bps) {
    lt.LibtorrentFlutter.instance.setUploadLimit(bps);
  }

  // FIX: [Audit] Convert rate limits from Bytes/s (NativeBtConfig standard) to KB/s for plugin BtConfig.
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
      downloadRateLimit: config.downloadRateLimit ~/ 1024,
      uploadRateLimit: config.uploadRateLimit ~/ 1024,
      peersListenPort: config.peersListenPort,
      responsiveMode: config.responsiveMode,
    ));
  }

  // FIX: [Audit] Convert rate limits from plugin BtConfig (KB/s) to Bytes/s for NativeBtConfig.
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
      downloadRateLimit: def.downloadRateLimit * 1024,
      uploadRateLimit: def.uploadRateLimit * 1024,
      peersListenPort: def.peersListenPort,
      responsiveMode: def.responsiveMode,
    );
  }

  @override
  List<NativeTrackerInfo> getTrackers(int id) {
    return lt.LibtorrentFlutter.instance.getTrackers(id).map((t) {
      return NativeTrackerInfo(
        url: t.url,
        tier: t.tier,
        status: t.status,
        seeds: t.seeds,
        peers: t.peers,
        message: t.message,
      );
    }).toList();
  }

  @override
  void addTracker(int id, String trackerUrl, {int tier = 0}) {
    lt.LibtorrentFlutter.instance.addTracker(id, trackerUrl, tier: tier);
  }

  @override
  void removeTracker(int id, String trackerUrl) {
    lt.LibtorrentFlutter.instance.removeTracker(id, trackerUrl);
  }

  @override
  void announceNow(int id) {
    lt.LibtorrentFlutter.instance.announceNow(id);
  }

  @override
  void setSequentialDownload(int id, bool enabled) {
    lt.LibtorrentFlutter.instance.setSequentialDownload(id, enabled);
  }

  @override
  void setSuperSeeding(int id, bool enabled) {
    lt.LibtorrentFlutter.instance.setSuperSeeding(id, enabled);
  }

  @override
  void setPieceDeadline(int id, int pieceIndex, int deadlineMs) {
    lt.LibtorrentFlutter.instance.setPieceDeadline(id, pieceIndex, deadlineMs);
  }

  @override
  Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  }) {
    return lt.LibtorrentFlutter.instance.createTorrent(
      sourcePath: sourcePath,
      outputPath: outputPath,
      trackers: trackers,
      comment: comment,
      pieceSize: pieceSize,
      isPrivate: isPrivate,
    );
  }

  @override
  Future<bool> loadIpFilter(String filePath) {
    return lt.LibtorrentFlutter.instance.loadIpFilter(filePath);
  }

  @override
  Future<void> setProxy({
    required String host,
    required int port,
    required int type,
    String? username,
    String? password,
  }) {
    return lt.LibtorrentFlutter.instance.setProxy(
      host: host,
      port: port,
      type: type,
      username: username,
      password: password,
    );
  }

  @override
  Future<void> setSslCertificate({
    required String certPath,
    required String privateKeyPath,
    String? dhParamsPath,
  }) {
    return lt.LibtorrentFlutter.instance.setSslCertificate(
      certPath: certPath,
      privateKeyPath: privateKeyPath,
      dhParamsPath: dhParamsPath,
    );
  }

  @override
  void addWebSeed(int id, String url) {
    lt.LibtorrentFlutter.instance.addWebSeed(id, url);
  }

  @override
  void removeWebSeed(int id, String url) {
    lt.LibtorrentFlutter.instance.removeWebSeed(id, url);
  }

  @override
  List<String> getWebSeeds(int id) {
    return lt.LibtorrentFlutter.instance.getWebSeeds(id);
  }
}
