import 'dart:async';
import 'dart:typed_data';

import 'package:dmx/core/domain/torrent_session_settings.dart';
import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/torrent_models.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;

/// Scriptable test fake for [ITorrentService] satisfying Phase 0 test harness requirements.
class FakeITorrentService implements ITorrentService {
  bool _isSupported = true;
  bool _isInitialized = true;
  final ValueNotifier<bool> _isAvailable = ValueNotifier<bool>(true);

  final StreamController<Map<int, TorrentUpdateInfo>> _torrentUpdatesCtrl =
      StreamController<Map<int, TorrentUpdateInfo>>.broadcast();
  final StreamController<TorrentAlertEvent> _alertUpdatesCtrl =
      StreamController<TorrentAlertEvent>.broadcast();

  final Map<int, TorrentUpdateInfo> _latestStats = {};
  final Map<int, bool> _isPausedMap = {};
  final Map<int, List<TorrentFileItem>> _files = {};
  final Map<int, List<int>> _filePriorities = {};
  final Map<int, List<TorrentFileProgress>> _fileProgress = {};
  final Map<int, Uint8List> _resumeBlobs = {};
  final Map<int, List<TrackerInfo>> _trackers = {};
  final Map<int, List<String>> _webSeeds = {};
  final Set<int> _activeTorrentIds = {};
  final List<int> pausedTorrents = [];
  final List<int> resumedTorrents = [];
  final List<int> forceStoppedTorrents = [];
  final List<int> recheckedTorrents = [];

  double simulatedShareRatioLimit = 2.0;
  int simulatedMaxSeedingTimeMinutes = 1440;
  String simulatedNativeVersion = 'libtorrent/2.0.9-fake';

  @override
  bool get isSupported => _isSupported;
  set isSupported(bool v) => _isSupported = v;

  @override
  bool get isInitialized => _isInitialized;
  set isInitialized(bool v) => _isInitialized = v;

  @override
  Future<void> get ready => Future.value();

  @override
  ValueNotifier<bool> get isAvailable => _isAvailable;

  @override
  Set<int> get activeTorrentIds => Set.unmodifiable(_activeTorrentIds);

  @override
  Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates =>
      _torrentUpdatesCtrl.stream;

  @override
  Map<int, TorrentUpdateInfo> get latestStats =>
      Map.unmodifiable(_latestStats);

  @override
  int? idForSource(String source) => null;

  @override
  Stream<TorrentAlertEvent> get alertUpdates => _alertUpdatesCtrl.stream;

  @override
  String get nativeVersion => simulatedNativeVersion;

  @override
  bool get fileProgressSupported => true;
  @override
  bool get filePrioritiesSupported => true;
  @override
  bool get resumeDataSupported => true;
  @override
  bool get forceRecheckSupported => true;
  @override
  bool get trackersSupported => true;
  @override
  bool get createTorrentSupported => true;
  @override
  bool get ipFilterSupported => true;
  @override
  bool get sequentialDownloadSupported => true;
  @override
  bool get superSeedingSupported => true;
  @override
  bool get pieceDeadlineSupported => true;
  @override
  bool get sequentialDownloadEnabled => false;
  @override
  bool get seedingEnabled => true;
  @override
  double get shareRatioLimit => simulatedShareRatioLimit;
  @override
  int get maxSeedingTimeMinutes => simulatedMaxSeedingTimeMinutes;

  bool isTorrentPaused(int id) => _isPausedMap[id] ?? false;

  void emitAlert(TorrentAlertEvent alert) {
    _alertUpdatesCtrl.add(alert);
  }

  void emitStats(Map<int, TorrentUpdateInfo> stats) {
    _latestStats.addAll(stats);
    _torrentUpdatesCtrl.add(Map.unmodifiable(_latestStats));
  }

  void seedTorrent({
    required int id,
    required String name,
    required int totalWanted,
    int totalWantedDone = 0,
    double progress = 0.0,
    int downloadRate = 1024 * 1024,
    int uploadRate = 0,
    int numPeers = 5,
    int numSeeds = 2,
    bool isPaused = false,
    bool isFinished = false,
    bool hasMetadata = true,
  }) {
    _activeTorrentIds.add(id);
    _isPausedMap[id] = isPaused;
    final info = TorrentUpdateInfo(
      id: id,
      name: name,
      progress: progress,
      downloadRate: isPaused ? 0 : downloadRate,
      uploadRate: isPaused ? 0 : uploadRate,
      totalWanted: totalWanted,
      totalWantedDone: totalWantedDone,
      totalDone: totalWantedDone,
      hasMetadata: hasMetadata,
      stateLabel: isPaused ? 'Paused' : (isFinished ? 'Seeding' : (hasMetadata ? 'Downloading' : 'Fetching Metadata')),
      numPeers: numPeers,
      numSeeds: numSeeds,
    );
    _latestStats[id] = info;
    _torrentUpdatesCtrl.add(Map.unmodifiable(_latestStats));
  }

  @override
  double progressFor(int id) => _latestStats[id]?.progress ?? 0.0;

  @override
  Uint8List? fetchResumeBytes(int id) => _resumeBlobs[id];

  @override
  Uint8List? resumeBlobFor(int id) => _resumeBlobs[id];

  @override
  Future<bool> hasResumeData(String source) async => true;

  @override
  Future<void> init() async {
    _isInitialized = true;
    _isAvailable.value = true;
  }

  @override
  Future<void> saveResumeData(int torrentId) async {
    final blob = Uint8List.fromList([0x64, 0x31, 0x30, 0x3a, 0x66, 0x61, 0x73, 0x74]);
    _resumeBlobs[torrentId] = blob;
    emitAlert(TorrentAlertEvent(
      type: 30, // saveResumeDataCompleted
      torrentId: torrentId,
      message: 'Fastresume data saved for $torrentId',
      timestamp: DateTime.now(),
    ));
  }

  @override
  Future<void> saveAllResumeData() async {
    for (final id in _activeTorrentIds) {
      await saveResumeData(id);
    }
  }

  @override
  Future<void> dispose() async {
    _isInitialized = false;
    _isAvailable.value = false;
  }

  @override
  int addMagnet(String magnetUri, String savePath, {List<int>? resumeData}) {
    final id = _latestStats.length + 1;
    _activeTorrentIds.add(id);
    _isPausedMap[id] = false;
    if (resumeData != null) _resumeBlobs[id] = Uint8List.fromList(resumeData);
    final info = TorrentUpdateInfo(
      id: id,
      name: 'Magnet_$id',
      progress: 0.0,
      downloadRate: 0,
      uploadRate: 0,
      totalWanted: 0,
      totalWantedDone: 0,
      totalDone: 0,
      hasMetadata: false,
      stateLabel: 'Fetching Metadata',
    );
    _latestStats[id] = info;
    _torrentUpdatesCtrl.add(Map.unmodifiable(_latestStats));
    return id;
  }

  @override
  Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 10),
    List<int>? resumeData,
  }) async {
    return addMagnet(magnetUri, savePath, resumeData: resumeData);
  }

  @override
  int addTorrentFile(String filePath, String savePath,
      {String? sourceKey, List<int>? resumeData}) {
    final id = _latestStats.length + 1;
    _activeTorrentIds.add(id);
    _isPausedMap[id] = false;
    if (resumeData != null) _resumeBlobs[id] = Uint8List.fromList(resumeData);
    final info = TorrentUpdateInfo(
      id: id,
      name: filePath.split('/').last,
      progress: 0.0,
      downloadRate: 0,
      uploadRate: 0,
      totalWanted: 1024 * 1024 * 100,
      totalWantedDone: 0,
      totalDone: 0,
      hasMetadata: true,
      stateLabel: 'Checking files',
    );
    _latestStats[id] = info;
    _torrentUpdatesCtrl.add(Map.unmodifiable(_latestStats));
    return id;
  }

  @override
  void removeTorrent(int id, {bool deleteFiles = false, bool deleteResumeData = false}) {
    _activeTorrentIds.remove(id);
    _latestStats.remove(id);
    _isPausedMap.remove(id);
    _files.remove(id);
    _filePriorities.remove(id);
    _fileProgress.remove(id);
    if (deleteResumeData) _resumeBlobs.remove(id);
    _torrentUpdatesCtrl.add(Map.unmodifiable(_latestStats));
  }

  @override
  Future<void> pauseTorrent(int id) async {
    pausedTorrents.add(id);
    _isPausedMap[id] = true;
    final st = _latestStats[id];
    if (st != null) {
      _latestStats[id] = TorrentUpdateInfo(
        id: st.id,
        name: st.name,
        progress: st.progress,
        downloadRate: 0,
        uploadRate: 0,
        totalDone: st.totalDone,
        totalWanted: st.totalWanted,
        totalWantedDone: st.totalWantedDone,
        hasMetadata: st.hasMetadata,
        stateLabel: 'Paused',
        numSeeds: st.numSeeds,
        numPeers: st.numPeers,
        fileProgress: st.fileProgress,
        filePriorities: st.filePriorities,
      );
      _torrentUpdatesCtrl.add(Map.unmodifiable(_latestStats));
    }
  }

  @override
  Future<void> forceStopTorrent(int id) async {
    forceStoppedTorrents.add(id);
    await pauseTorrent(id);
    _activeTorrentIds.remove(id);
  }

  @override
  Future<void> resumeTorrent(int id) async {
    resumedTorrents.add(id);
    _isPausedMap[id] = false;
    final st = _latestStats[id];
    if (st != null) {
      _latestStats[id] = TorrentUpdateInfo(
        id: st.id,
        name: st.name,
        progress: st.progress,
        downloadRate: 1024 * 512,
        uploadRate: 0,
        totalDone: st.totalDone,
        totalWanted: st.totalWanted,
        totalWantedDone: st.totalWantedDone,
        hasMetadata: st.hasMetadata,
        stateLabel: 'Downloading',
        numSeeds: st.numSeeds,
        numPeers: st.numPeers,
        fileProgress: st.fileProgress,
        filePriorities: st.filePriorities,
      );
      _torrentUpdatesCtrl.add(Map.unmodifiable(_latestStats));
    }
  }

  @override
  bool loadResumeData(int id, List<int> data) {
    _resumeBlobs[id] = Uint8List.fromList(data);
    return true;
  }

  @override
  bool isTorrentAlive(int id) => _activeTorrentIds.contains(id);

  @override
  void recheckTorrent(int id) {
    recheckedTorrents.add(id);
    final st = _latestStats[id];
    if (st != null) {
      _latestStats[id] = TorrentUpdateInfo(
        id: st.id,
        name: st.name,
        progress: 0.0,
        downloadRate: 0,
        uploadRate: 0,
        totalDone: 0,
        totalWanted: st.totalWanted,
        totalWantedDone: 0,
        hasMetadata: st.hasMetadata,
        stateLabel: 'Checking files',
        numSeeds: st.numSeeds,
        numPeers: st.numPeers,
        fileProgress: st.fileProgress,
        filePriorities: st.filePriorities,
      );
      _torrentUpdatesCtrl.add(Map.unmodifiable(_latestStats));
    }
  }

  @override
  void setFilePriorities(int id, List<int> priorities) {
    _filePriorities[id] = List.from(priorities);
  }

  @override
  int getFileCount(int id) => _files[id]?.length ?? 0;

  @override
  void setUploadLimit(int bps) {}

  @override
  void setDownloadLimit(int bps) {}

  @override
  List<TorrentFileItem> getFiles(int id) => _files[id] ?? const [];

  @override
  Map<String, dynamic>? getTorrentSnapshot(int id) {
    final st = _latestStats[id];
    if (st == null) return null;
    return {
      'id': id,
      'progress': st.progress,
      'totalWanted': st.totalWanted,
      'totalWantedDone': st.totalWantedDone,
      'state': st.stateLabel,
      'isPaused': isTorrentPaused(id),
    };
  }

  @override
  void configureSession([TorrentSessionSettings? settings]) {}

  @override
  void reconfigureSession() {}

  @override
  void autoEnableSequentialForVideo(int torrentId) {}

  @override
  Future<void> autoSaveResumeData() async {
    await saveAllResumeData();
  }

  @override
  List<TrackerInfo> getTrackers(int torrentId) => _trackers[torrentId] ?? const [];

  @override
  void addTracker(int torrentId, String trackerUrl, {int tier = 0}) {
    final list = _trackers.putIfAbsent(torrentId, () => []);
    list.add(TrackerInfo(
      url: trackerUrl,
      tier: tier,
      status: 'working',
      seeds: 10,
      peers: 20,
      message: 'OK',
    ));
  }

  @override
  void removeTracker(int torrentId, String trackerUrl) {
    _trackers[torrentId]?.removeWhere((t) => t.url == trackerUrl);
  }

  @override
  void announceNow(int torrentId) {}

  @override
  void boostMagnetDiscovery(int torrentId) {}

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
  Future<bool> downloadAndApplyBlocklist(String url) async => true;

  @override
  void enableSequentialDownload(int torrentId, bool enabled) {}

  @override
  void setSequentialDownload(int torrentId, bool enabled) {}

  @override
  void prioritizeFile(int torrentId, int fileIndex, {int priority = 7}) {}

  @override
  void setPieceDeadline(int torrentId, int pieceIndex, int deadlineMs) {}

  @override
  void enableSuperSeeding(int torrentId, bool enabled) {}

  @override
  List<TorrentAlertEvent> getRecentAlerts([int? torrentId]) => const [];

  @override
  void applySettingsPack(TorrentSettingsPack pack) {}

  @override
  Future<List<TorrentFileProgress>> getAccurateFileProgress(int torrentId, String savePath) async {
    return _fileProgress[torrentId] ?? const [];
  }

  @override
  Future<Map<String, dynamic>?> getPieceProgress(int torrentId) async => null;

  @override
  Future<List<PeerConnectionQuality>> getPeers(int torrentId) async => const [];

  @override
  Future<void> setProxy({
    required String host,
    required int port,
    required ProxyType type,
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
  void addWebSeed(int torrentId, String url) {
    final list = _webSeeds.putIfAbsent(torrentId, () => []);
    if (!list.contains(url)) list.add(url);
  }

  @override
  void removeWebSeed(int torrentId, String url) {
    _webSeeds[torrentId]?.remove(url);
  }

  @override
  List<String> getWebSeeds(int torrentId) => _webSeeds[torrentId] ?? const [];

  @override
  bool shouldStopSeeding({
    required double progress,
    required int uploadedBytes,
    int? totalBytes,
    int? downloadedBytes,
    Duration? seedingDuration,
    double? shareRatioLimit,
    double? customRatioLimit,
    int? maxSeedingMinutes,
    int? customMaxTimeMinutes,
    DateTime? completedAt,
  }) {
    if (progress < 1.0) return false;
    final limit = customRatioLimit ?? shareRatioLimit ?? simulatedShareRatioLimit;
    if (limit > 0 && downloadedBytes != null && downloadedBytes > 0) {
      if ((uploadedBytes / downloadedBytes) >= limit) return true;
    }
    return false;
  }
}
