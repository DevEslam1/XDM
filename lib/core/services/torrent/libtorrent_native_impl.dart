import 'dart:async';
import 'package:libtorrent_flutter/libtorrent_flutter.dart' as lt;

import '../../interfaces/i_torrent_native.dart';

/// Concrete implementation of [ITorrentNative] backed by the vendored `libtorrent_flutter`.
class LibtorrentNativeImpl implements ITorrentNative {
  LibtorrentNativeImpl();

  StreamSubscription<lt.LtAlert>? _alertSub;
  final StreamController<NativeAlertEvent> _alertStreamCtrl =
      StreamController<NativeAlertEvent>.broadcast();

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
  Stream<NativeAlertEvent> get alertStream => _alertStreamCtrl.stream;

  @override
  Stream<Map<int, NativeTorrentStatus>> get statusStream {
    if (!isInitialized) return const Stream.empty();
    return lt.LibtorrentFlutter.instance.torrentUpdates.map((map) {
      return map.map((key, value) => MapEntry(key, _mapStatus(value)));
    });
  }

  NativeTorrentStatus _mapStatus(lt.TorrentInfo info) {
    return NativeTorrentStatus(
      id: info.id,
      name: info.name,
      savePath: info.savePath,
      errorMsg: info.errorMsg,
      state: info.state.index,
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
      numPieces: info.numPieces,
      piecesDone: info.piecesDone,
      pieces: info.pieces,
      isPaused: info.isPaused,
      isFinished: info.isFinished,
      hasMetadata: info.hasMetadata,
      queuePosition: info.queuePosition,
      fileProgress: info.fileProgress,
      filePriorities: info.filePriorities,
    );
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
    if (lt.LibtorrentFlutter.isInitialized) return;
    await lt.LibtorrentFlutter.init(
      listenInterface: listenInterface,
      downloadLimit: downloadLimit,
      uploadLimit: uploadLimit,
      pollInterval: pollInterval,
      fetchTrackers: fetchTrackers,
      defaultSavePath: defaultSavePath,
    );

    _alertSub?.cancel();
    _alertSub = lt.LibtorrentFlutter.instance.alertUpdates.listen((alert) {
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

  @override
  Future<void> dispose() async {
    await _alertSub?.cancel();
    _alertSub = null;
    if (lt.LibtorrentFlutter.isInitialized) {
      await lt.LibtorrentFlutter.instance.dispose();
    }
  }

  @override
  int addMagnet(String magnetUri, String savePath, {bool streamOnly = false}) {
    return lt.LibtorrentFlutter.instance.addMagnet(magnetUri, savePath, streamOnly);
  }

  @override
  int addTorrentFile(String filePath, String savePath, {bool streamOnly = false}) {
    return lt.LibtorrentFlutter.instance.addTorrentFile(filePath, savePath, streamOnly);
  }

  @override
  void removeTorrent(int id, {bool deleteFiles = false}) {
    lt.LibtorrentFlutter.instance.removeTorrent(id, deleteFiles: deleteFiles);
  }

  @override
  Future<void> pauseTorrent(int id, {bool graceful = true}) async {
    lt.LibtorrentFlutter.instance.pauseTorrent(id, graceful: graceful);
  }

  @override
  void resumeTorrent(int id) {
    lt.LibtorrentFlutter.instance.resumeTorrent(id);
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
      downloadRateLimit: config.downloadRateLimit,
      uploadRateLimit: config.uploadRateLimit,
      peersListenPort: config.peersListenPort,
      responsiveMode: config.responsiveMode,
    ));
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
      downloadRateLimit: def.downloadRateLimit,
      uploadRateLimit: def.uploadRateLimit,
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
