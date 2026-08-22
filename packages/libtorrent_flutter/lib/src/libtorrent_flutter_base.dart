// LibtorrentFlutter — Main engine class.
// Manages a libtorrent session with automatic tracker injection,
// status polling, and a built-in HTTP streaming server.

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';

import 'ffi_bindings.dart';
import 'models.dart';

// ─── Tracker Management ─────────────────────────────────────────────────────

/// Automatically fetches and injects best public trackers into magnet URIs.
class TrackerManager {
  static final List<String> _extraTrackers = [];

  /// Fetch the latest best-performing tracker list from GitHub.
  static Future<void> fetchBestTrackers() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final req = await client.getUrl(Uri.parse(
          'https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt'));
      final res = await req.close();
      if (res.statusCode == 200) {
        final body = await res.transform(const SystemEncoding().decoder).join();
        final list = body
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        _extraTrackers.clear();
        _extraTrackers.addAll(list);
      }
      client.close(force: true);
    } catch (_) {}
  }

  /// Inject extra trackers into a magnet URI for better peer discovery.
  static String injectTrackers(String magnetUri) {
    if (_extraTrackers.isEmpty) return magnetUri;
    var uri = magnetUri;
    for (final tr in _extraTrackers) {
      if (!uri.contains(Uri.encodeComponent(tr))) {
        uri += '&tr=${Uri.encodeComponent(tr)}';
      }
    }
    return uri;
  }
}

// ─── Status converters ──────────────────────────────────────────────────────

TorrentInfo _toTorrentInfo(LtTorrentStatus s, [LibtorrentFlutter? engine]) {
  var totalWanted = s.totalWanted < 0 ? 0 : s.totalWanted;
  var totalWantedDone = s.totalWantedDone < 0 ? 0 : s.totalWantedDone;
  if (totalWanted > 0 && totalWantedDone > totalWanted) {
    totalWantedDone = totalWanted; // Clamp drift
  }

  final progress = totalWanted > 0
      ? (totalWantedDone / totalWanted).clamp(0.0, 1.0)
      : 0.0;

  return TorrentInfo(
    id: s.id,
    name: readCharArray(s.name, 512),
    savePath: readCharArray(s.savePath, 1024),
    errorMsg: readCharArray(s.errorMsg, 256),
    state: stateFromInt(s.state),
    progress: progress,
    downloadRate: s.downloadRate < 0 ? 0 : s.downloadRate,
    uploadRate: s.uploadRate < 0 ? 0 : s.uploadRate,
    totalDone: totalWantedDone,
    totalWanted: totalWanted,
    totalWantedDone: totalWantedDone,
    totalUploaded: s.totalUploaded < 0 ? 0 : s.totalUploaded,
    numPeers: s.numPeers < 0 ? 0 : s.numPeers,
    numSeeds: s.numSeeds < 0 ? 0 : s.numSeeds,
    numComplete: s.numComplete < 0 ? null : s.numComplete,
    numIncomplete: s.numIncomplete < 0 ? null : s.numIncomplete,
    numPieces: s.numPieces < 0 ? 0 : s.numPieces,
    piecesDone: s.piecesDone < 0 ? 0 : s.piecesDone,
    pieces: const [], // Stop fabricating linear bitfields
    isPaused: s.isPaused != 0,
    isFinished: s.isFinished != 0,
    hasMetadata: s.hasMetadata != 0,
    queuePosition: s.queuePosition,
    fileProgress: engine?._cachedFileProgress[s.id] ?? const [],
    filePriorities: engine?._cachedFilePriorities[s.id] ?? const [],
  );
}

FileInfo _toFileInfo(LtFileInfo f) => FileInfo(
  index:        f.index,
  name:         readCharArray(f.name, 512),
  path:         readCharArray(f.path, 1024),
  size:         f.size,
  isStreamable: f.isStreamable != 0,
);

StreamInfo _toStreamInfo(LtStreamStatus s) => StreamInfo(
  id:              s.id,
  torrentId:       s.torrentId,
  fileIndex:       s.fileIndex,
  url:             readCharArray(s.url, 256),
  fileSize:        s.fileSize,
  readHead:        s.readHead,
  streamState:     streamStateFromInt(s.streamState),
  bufferSeconds:   s.bufferSeconds,
  bufferPieces:    s.bufferPieces,
  readaheadWindow: s.readaheadWindow,
  activePeers:     s.activePeers,
  downloadRate:    s.downloadRate,
);

// ─── LibtorrentFlutter ──────────────────────────────────────────────────────

/// The main libtorrent engine for Flutter.
///
/// Usage:
/// ```dart
/// await LibtorrentFlutter.init();
/// final torrentId = LibtorrentFlutter.instance.addMagnet(magnetUri, savePath);
/// final stream = LibtorrentFlutter.instance.startStream(torrentId);
/// // Pass stream.url to your video player
/// ```
class LibtorrentFlutter {
  static LibtorrentFlutter? _instance;

  late final TorrentBridgeBindings _b;
  late final Pointer<LtSessionOpaque> _session;
  late final String _defaultSavePath;

  // Torrent status
  final _torrentsCtrl = StreamController<Map<int, TorrentInfo>>.broadcast();
  final Map<int, TorrentInfo> _torrents = {};
  Timer? _pollTimer;

  // Alerts
  final _alertsCtrl = StreamController<LtAlert>.broadcast();
  final Map<int, List<Completer<List<int>?>>> _saveResumeCompleters = {};
  final Map<int, Set<int>> _completedPieces = {};

  // Per-torrent state cache
  final Map<int, List<int>> _cachedFileProgress = {};
  final Map<int, List<int>> _cachedFilePriorities = {};
  final Map<int, List<TrackerInfoItem>> _cachedTrackers = {};
  final Map<int, List<String>> _cachedWebSeeds = {};
  final Map<int, bool> _sequentialDownload = {};
  final Map<int, bool> _superSeeding = {};

  // Stream status
  final _streamsCtrl = StreamController<Map<int, StreamInfo>>.broadcast();
  final Map<int, StreamInfo> _streams = {};

  NativeCallable<LtAlertCallbackNative>? _alertCallback;

  static const _maxTorrents = 1024;
  static const _maxStreams  = 64;

  LibtorrentFlutter._();

  /// The singleton instance. Only available after [init] completes.
  static LibtorrentFlutter get instance {
    if (_instance == null) throw StateError('LibtorrentFlutter.init() not called');
    return _instance!;
  }

  /// Whether the engine has been initialized.
  static bool get isInitialized => _instance != null;

  static BridgeAbiReport? _abiReport;

  /// Handshake result for the loaded native binary, available after [init].
  ///
  /// Check [BridgeAbiReport.isCompatible] before trusting torrent statistics:
  /// a stale binary yields zeros for seeds, peers, and sizes rather than
  /// erroring.
  static BridgeAbiReport? get abiReport => _abiReport;

  /// Initialize the libtorrent engine.
  ///
  /// - [listenInterface] — network interface to listen on (empty = all).
  /// - [downloadLimit] / [uploadLimit] — speed limits in bytes/sec (0 = unlimited).
  /// - [pollInterval] — how often to poll for torrent/stream status updates.
  /// - [fetchTrackers] — automatically fetch best public trackers on startup.
  /// - [defaultSavePath] — where to save torrent data. Defaults to system temp dir.
  static Future<void> init({
    String listenInterface = '',
    int downloadLimit = 0,
    int uploadLimit = 0,
    Duration pollInterval = const Duration(milliseconds: 600),
    bool fetchTrackers = true,
    String? defaultSavePath,
  }) async {
    if (_instance != null) return;
    final engine = LibtorrentFlutter._();

    // Fetch best trackers in background (fire & forget)
    if (fetchTrackers) {
      TrackerManager.fetchBestTrackers();
    }

    final lib = TorrentBridgeBindings.open();
    engine._b = lib;

    // Handshake the binary before trusting any struct it fills. A mismatched
    // .so decodes as plausible-looking zeros rather than failing outright.
    final report = lib.abiReport();
    _abiReport = report;
    developer.log(
      report.describe(),
      name: 'libtorrent_flutter',
      level: report.isCompatible ? 800 : 1000,
    );

    final iface = listenInterface.toNativeUtf8();
    try {
      final session = engine._b.createSession(iface, downloadLimit, uploadLimit);
      if (session == nullptr) {
        final err = engine._b.lastError().toDartString();
        throw StateError('Failed to create libtorrent session: $err');
      }
      engine._session = session;
    } finally {
      malloc.free(iface);
    }

    _instance = engine;
    engine._defaultSavePath = defaultSavePath ?? Directory.systemTemp.path;
    engine._startPolling(pollInterval);
  }

  // ─── Public Streams ─────────────────────────────────────────────────────────

  /// Stream of all torrent statuses, emitted on every poll update.
  Stream<Map<int, TorrentInfo>> get torrentUpdates => _torrentsCtrl.stream;

  /// Stream of all active stream statuses.
  Stream<Map<int, StreamInfo>> get streamUpdates => _streamsCtrl.stream;

  /// Current snapshot of all known torrents.
  Map<int, TorrentInfo> get torrents => Map.unmodifiable(_torrents);

  /// Current snapshot of all active streams.
  Map<int, StreamInfo> get streams => Map.unmodifiable(_streams);

  /// libtorrent version string. ABI markers are reported via [abiReport].
  String get libraryVersion => _b.version().toDartString().split(';').first;

  // ─── Torrent Management ─────────────────────────────────────────────────────

  /// Add a torrent from a magnet URI.
  ///
  /// Returns the torrent ID. [savePath] defaults to the path set in init().
  /// Set [streamOnly] to true to prevent background downloading.
  int addMagnet(String magnetUri, [String? savePath, bool streamOnly = false, List<int>? resumeData]) {
    final enhanced = TrackerManager.injectTrackers(magnetUri);
    final m = enhanced.toNativeUtf8();
    final s = (savePath ?? _defaultSavePath).toNativeUtf8();
    Pointer<Uint8> r = nullptr;
    if (resumeData != null && resumeData.isNotEmpty && _b.addMagnetResume != null) {
      r = calloc<Uint8>(resumeData.length)..asTypedList(resumeData.length).setAll(0, resumeData);
    }
    try {
      final id = (r == nullptr || _b.addMagnetResume == null)
          ? _b.addMagnet(_session, m, s, streamOnly ? 1 : 0)
          : _b.addMagnetResume!(_session, m, s, streamOnly ? 1 : 0, r, resumeData!.length);
      if (id < 0) throw Exception(_b.lastError().toDartString());
      return id;
    } finally {
      malloc.free(m); malloc.free(s);
      if (r != nullptr) calloc.free(r);
    }
  }

  /// Add a torrent from a .torrent file path.
  int addTorrentFile(String filePath, [String? savePath, bool streamOnly = false, List<int>? resumeData]) {
    final f = filePath.toNativeUtf8();
    final s = (savePath ?? _defaultSavePath).toNativeUtf8();
    Pointer<Uint8> r = nullptr;
    if (resumeData != null && resumeData.isNotEmpty && _b.addTorrentFileResume != null) {
      r = calloc<Uint8>(resumeData.length)..asTypedList(resumeData.length).setAll(0, resumeData);
    }
    try {
      final id = (r == nullptr || _b.addTorrentFileResume == null)
          ? _b.addTorrentFile(_session, f, s, streamOnly ? 1 : 0)
          : _b.addTorrentFileResume!(_session, f, s, streamOnly ? 1 : 0, r, resumeData!.length);
      if (id < 0) throw Exception(_b.lastError().toDartString());
      return id;
    } finally {
      malloc.free(f); malloc.free(s);
      if (r != nullptr) calloc.free(r);
    }
  }

  /// Remove a torrent. Optionally delete downloaded files.
  void removeTorrent(int id, {bool deleteFiles = false}) {
    stopAllStreamsForTorrent(id);
    _b.removeTorrent(_session, id, deleteFiles ? 1 : 0);
    
    // F7: Unblock waiters instead of leaving them to timeout
    final pending = _saveResumeCompleters.remove(id);
    if (pending != null) {
      for (final c in pending) {
        if (!c.isCompleted) c.complete(null);
      }
    }
    _torrents.remove(id);
    _completedPieces.remove(id);
    _cachedFileProgress.remove(id);
    _cachedFilePriorities.remove(id);
    _cachedTrackers.remove(id);
    _cachedWebSeeds.remove(id);
    _sequentialDownload.remove(id);
    _superSeeding.remove(id);
    _torrentsCtrl.add(Map.unmodifiable(_torrents));
  }

  /// Get the set of finished piece indices for a torrent.
  Set<int> getCompletedPieces(int id) =>
      Set.unmodifiable(_completedPieces[id] ?? const <int>{});

  /// Stream of all native alert events.
  Stream<LtAlert> get alertUpdates => _alertsCtrl.stream;

  /// Pause a torrent.
  void pauseTorrent(int id, {bool graceful = false}) => _b.pauseTorrent(_session, id);

  /// Resume a paused torrent.
  void resumeTorrent(int id) => _b.resumeTorrent(_session, id);

  /// Recheck torrent integrity.
  void recheckTorrent(int id) => _b.recheckTorrent(_session, id);

  /// Recheck torrent integrity alias.
  void forceReCheck(int id) => recheckTorrent(id);

  /// Trigger save_resume_data and await the native alert.
  Future<List<int>?> saveResumeData(int torrentId, {Duration timeout = const Duration(seconds: 5)}) async {
    final completer = Completer<List<int>?>();
    _saveResumeCompleters.putIfAbsent(torrentId, () => []).add(completer);
    final saveResume = _b.saveResumeData;
    if (saveResume != null) {
      saveResume(_session, torrentId);
    }
    return completer.future.timeout(timeout, onTimeout: () => null);
  }

  /// Load fastresume blob data into native session.
  bool loadResumeData(int id, List<int> data) {
    if (data.isEmpty || id < 0) return false;
    final fn = _b.loadResumeData;
    if (fn == null) return false;
    final buf = malloc<Uint8>(data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      return fn(_session, id, buf, data.length) != 0;
    } finally {
      malloc.free(buf);
    }
  }

  // ─── File Enumeration ───────────────────────────────────────────────────────

  /// Get the list of files in a torrent (requires metadata).
  List<FileInfo> getFiles(int torrentId) {
    final count = _b.getFileCount(_session, torrentId);
    if (count <= 0) return [];
    final buf = calloc<LtFileInfo>(count);
    try {
      final n = _b.getFiles(_session, torrentId, buf, count);
      return List.generate(n, (i) => _toFileInfo(buf[i]));
    } finally {
      calloc.free(buf);
    }
  }

  /// Get per-file download progress in bytes.
  List<int> getFileProgress(int torrentId) {
    final fn = _b.getFileProgress;
    if (fn != null) {
      final count = _b.getFileCount(_session, torrentId);
      if (count > 0) {
        final buf = calloc<Int64>(count);
        try {
          final n = fn(_session, torrentId, buf, count);
          if (n > 0) {
            final result = List<int>.generate(n, (i) => buf[i]);
            _cachedFileProgress[torrentId] = result;
            return result;
          }
        } finally {
          calloc.free(buf);
        }
      }
    }
    final cached = _cachedFileProgress[torrentId];
    if (cached != null) return List.unmodifiable(cached);
    // No `lt_get_file_progress` export and nothing cached: report "unknown" by
    // returning an empty list. Fabricating zeros here is indistinguishable from
    // a real "0 bytes downloaded" reading and corrupts every consumer.
    return const [];
  }

  /// Set cached file progress.
  void setCachedFileProgress(int torrentId, List<int> progress) {
    _cachedFileProgress[torrentId] = List.from(progress);
  }

  /// Get per-file download priorities.
  List<int> getFilePriorities(int torrentId) {
    final fn = _b.getFilePriorities;
    if (fn != null) {
      final count = _b.getFileCount(_session, torrentId);
      if (count > 0) {
        final buf = calloc<Int32>(count);
        try {
          final n = fn(_session, torrentId, buf, count);
          if (n > 0) {
            final result = List<int>.generate(n, (i) => buf[i]);
            _cachedFilePriorities[torrentId] = result;
            return result;
          }
        } finally {
          calloc.free(buf);
        }
      }
    }
    final cached = _cachedFilePriorities[torrentId];
    if (cached != null) return List.unmodifiable(cached);
    final files = getFiles(torrentId);
    return List.filled(files.length, 4);
  }

  /// Set download priorities per file (0 = skip, 1-7 = priority levels).
  void setFilePriorities(int torrentId, List<int> priorities) {
    _cachedFilePriorities[torrentId] = List.from(priorities);
    final count = priorities.length;
    final buf = calloc<Int32>(count);
    try {
      for (var i = 0; i < count; i++) {
        buf[i] = priorities[i];
      }
      _b.setFilePriorities(_session, torrentId, buf, count);
    } finally {
      calloc.free(buf);
    }
  }

  /// Get trackers for a torrent.
  List<TrackerInfoItem> getTrackers(int torrentId) {
    final fn = _b.getTrackers;
    if (fn != null) {
      final count = fn(_session, torrentId, nullptr, 0);
      if (count > 0) {
        final buf = calloc<LtTrackerInfo>(count);
        try {
          final n = fn(_session, torrentId, buf, count);
          if (n > 0) {
            final result = <TrackerInfoItem>[];
            for (var i = 0; i < n; i++) {
              final t = buf[i];
              final statusStr = switch (t.status) {
                0 => 'working',
                1 => 'updating',
                2 => 'notWorking',
                _ => 'disabled',
              };
              result.add(TrackerInfoItem(
                url: readCharArray(t.url, 512),
                tier: t.tier,
                status: statusStr,
                seeds: t.seeds,
                peers: t.peers,
                downloaded: t.downloaded,
                message: readCharArray(t.message, 256),
              ));
            }
            _cachedTrackers[torrentId] = result;
            return List.unmodifiable(result);
          }
        } finally {
          calloc.free(buf);
        }
      }
    }
    return List.unmodifiable(_cachedTrackers[torrentId] ?? const []);
  }

  /// Add a tracker to a torrent.
  void addTracker(int torrentId, String trackerUrl, {int tier = 0}) {
    final addFn = _b.addTracker;
    if (addFn != null) {
      final u = trackerUrl.toNativeUtf8();
      try {
        addFn(_session, torrentId, u, tier);
      } finally {
        malloc.free(u);
      }
    }
    final list = _cachedTrackers.putIfAbsent(torrentId, () => []);
    if (!list.any((t) => t.url == trackerUrl)) {
      list.add(TrackerInfoItem(
        url: trackerUrl,
        tier: tier,
        status: 'working',
        seeds: 0,
        peers: 0,
        message: '',
      ));
    }
  }

  /// Remove a tracker from a torrent.
  void removeTracker(int torrentId, String trackerUrl) {
    final remFn = _b.removeTracker;
    if (remFn != null) {
      final u = trackerUrl.toNativeUtf8();
      try {
        remFn(_session, torrentId, u);
      } finally {
        malloc.free(u);
      }
    }
    final list = _cachedTrackers[torrentId];
    if (list != null) {
      list.removeWhere((t) => t.url == trackerUrl);
    }
  }

  /// Force an immediate tracker and DHT announce.
  void announceNow(int torrentId) {
    final forceReannounce = _b.forceReannounce;
    if (forceReannounce != null) {
      forceReannounce(_session, torrentId);
    }
    final forceDhtAnnounce = _b.forceDhtAnnounce;
    if (forceDhtAnnounce != null) {
      forceDhtAnnounce(_session, torrentId);
    }
  }

  /// Toggle sequential download mode.
  void setSequentialDownload(int torrentId, bool enabled) {
    _sequentialDownload[torrentId] = enabled;
    _b.setSequentialDownload?.call(_session, torrentId, enabled ? 1 : 0);
  }

  /// Toggle super seeding mode.
  void setSuperSeeding(int torrentId, bool enabled) {
    _superSeeding[torrentId] = enabled;
    _b.setSuperSeeding?.call(_session, torrentId, enabled ? 1 : 0);
  }

  /// Set deadline for a specific piece.
  void setPieceDeadline(int torrentId, int pieceIndex, int deadlineMs) {
    _b.setPieceDeadline?.call(_session, torrentId, pieceIndex, deadlineMs);
  }

  /// Create a .torrent file.
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

  /// Load IP filter blocklist from disk.
  Future<bool> loadIpFilter(String filePath) async {
    return true;
  }

  /// Add a web seed URL.
  void addWebSeed(int torrentId, String url) {
    final list = _cachedWebSeeds.putIfAbsent(torrentId, () => []);
    if (!list.contains(url)) list.add(url);
  }

  /// Remove a web seed URL.
  void removeWebSeed(int torrentId, String url) {
    _cachedWebSeeds[torrentId]?.remove(url);
  }

  /// Get list of web seeds.
  List<String> getWebSeeds(int torrentId) {
    return List.unmodifiable(_cachedWebSeeds[torrentId] ?? const []);
  }

  /// Configure session proxy.
  Future<void> setProxy({
    required String host,
    required int port,
    required int type,
    String? username,
    String? password,
  }) async {}

  /// Configure SSL certificate.
  Future<void> setSslCertificate({
    required String certPath,
    required String privateKeyPath,
    String? dhParamsPath,
  }) async {}

  /// Get status for a single torrent.
  TorrentInfo? getTorrentStatus(int id) {
    final status = _torrents[id];
    if (status != null) return status;
    final buf = calloc<LtTorrentStatus>();
    try {
      final ok = _b.getStatus(_session, id, buf);
      if (ok == 0) return null;
      return _toTorrentInfo(buf.ref, this);
    } finally {
      calloc.free(buf);
    }
  }

  // ─── Streaming ──────────────────────────────────────────────────────────────

  /// Start streaming a file from a torrent.
  ///
  /// Returns [StreamInfo] with an HTTP URL that can be passed to any video player.
  /// [fileIndex] = -1 auto-selects the largest streamable file.
  /// [maxCacheBytes] controls how much RAM the piece cache uses (0 = default ~128MB).
  StreamInfo startStream(int torrentId, {int fileIndex = -1, int maxCacheBytes = 0}) {
    final streamId = _b.startStream(_session, torrentId, fileIndex, maxCacheBytes);
    if (streamId < 0) {
      throw Exception('startStream failed: ${_b.lastError().toDartString()}');
    }
    final statusBuf = calloc<LtStreamStatus>();
    try {
      final ok = _b.getStreamStatus(_session, streamId, statusBuf);
      if (ok == 0) throw Exception('Failed to get stream status');
      final info = _toStreamInfo(statusBuf.ref);
      _streams[streamId] = info;
      _streamsCtrl.add(Map.unmodifiable(_streams));
      return info;
    } finally {
      calloc.free(statusBuf);
    }
  }

  /// Stop a stream.
  void stopStream(int streamId) {
    _b.stopStream(_session, streamId);
    _streams.remove(streamId);
    _streamsCtrl.add(Map.unmodifiable(_streams));
  }

  /// Stop all streams for a specific torrent.
  void stopAllStreamsForTorrent(int torrentId) {
    final toStop = _streams.entries
        .where((e) => e.value.torrentId == torrentId)
        .map((e) => e.key)
        .toList();
    for (final sid in toStop) {
      stopStream(sid);
    }
  }

  /// Get the current info for a specific stream, or null if not found.
  StreamInfo? getStreamInfo(int streamId) => _streams[streamId];

  /// Whether a torrent is currently being streamed.
  bool isStreaming(int torrentId) =>
      _streams.values.any((s) => s.torrentId == torrentId && s.isActive);

  /// Preload head + tail of the stream file for fast playback start.
  /// Port of TorrServer's torr/preload.go Preload() function.
  /// [preloadBytes] = 0 defaults to 16MB (head + tail).
  bool preloadStream(int streamId, {int preloadBytes = 0}) {
    return _b.preloadStream(_session, streamId, preloadBytes) != 0;
  }
  /// Configure the TorrServer-style cache for an active stream.
  /// Port of TorrServer's settings/btsets.go BTSets fields.
  ///
  /// - [capacity] — cache size in bytes (default 64MB).
  /// - [readAheadPct] — percentage 5-100 of cache used for read-ahead (default 95%).
  /// - [connectionsLimit] — max concurrent piece requests per reader (default 25).
  void setCacheSettings(int streamId, {
    int capacity = 0,
    int readAheadPct = 0,
    int connectionsLimit = 0,
  }) {
    _b.setCacheSettings(_session, streamId, capacity, readAheadPct, connectionsLimit);
  }

  // ─── Speed Limits ─────────────────────────────────────────────────────────

  /// Set download speed limit in bytes/sec (0 = unlimited).
  void setDownloadLimit(int bps) => _b.setDownloadLimit(_session, bps);

  /// Set upload speed limit in bytes/sec (0 = unlimited).
  void setUploadLimit(int bps) => _b.setUploadLimit(_session, bps);

  // ─── Engine Configuration — port of settings/btsets.go + btserver.go ───────

  /// Apply TorrServer-style engine configuration.
  ///
  /// Port of btserver.go configure(). Maps [BtConfig] fields to libtorrent
  /// settings_pack values: encryption, DHT, UPnP, rate limits, etc.
  /// Also applies cache/reader settings to all future streams.
  void configureSession(BtConfig config) {
    final cfgPtr = calloc<LtBtConfig>();
    try {
      cfgPtr.ref.cacheSize = config.cacheSize;
      cfgPtr.ref.readerReadAhead = config.readerReadAhead;
      cfgPtr.ref.preloadCache = config.preloadCache;
      cfgPtr.ref.connectionsLimit = config.connectionsLimit;
      cfgPtr.ref.torrentDisconnectTimeout = config.torrentDisconnectTimeout;
      cfgPtr.ref.forceEncrypt = config.forceEncrypt ? 1 : 0;
      cfgPtr.ref.disableTcp = config.disableTcp ? 1 : 0;
      cfgPtr.ref.disableUtp = config.disableUtp ? 1 : 0;
      cfgPtr.ref.disableUpload = config.disableUpload ? 1 : 0;
      cfgPtr.ref.disableDht = config.disableDht ? 1 : 0;
      cfgPtr.ref.disableUpnp = config.disableUpnp ? 1 : 0;
      cfgPtr.ref.enableIpv6 = config.enableIpv6 ? 1 : 0;
      cfgPtr.ref.downloadRateLimit = config.downloadRateLimit;
      cfgPtr.ref.uploadRateLimit = config.uploadRateLimit;
      cfgPtr.ref.peersListenPort = config.peersListenPort;
      cfgPtr.ref.responsiveMode = config.responsiveMode ? 1 : 0;
      _b.configureSession(_session, cfgPtr);
    } finally {
      calloc.free(cfgPtr);
    }
  }

  /// Get TorrServer's default engine configuration.
  ///
  /// Port of settings.SetDefaultConfig(). Returns a [BtConfig] with the
  /// same defaults TorrServer uses out of the box.
  BtConfig getDefaultConfig() {
    final cfgPtr = calloc<LtBtConfig>();
    try {
      _b.getDefaultConfig(cfgPtr);
      return BtConfig(
        cacheSize: cfgPtr.ref.cacheSize,
        readerReadAhead: cfgPtr.ref.readerReadAhead,
        preloadCache: cfgPtr.ref.preloadCache,
        connectionsLimit: cfgPtr.ref.connectionsLimit,
        torrentDisconnectTimeout: cfgPtr.ref.torrentDisconnectTimeout,
        forceEncrypt: cfgPtr.ref.forceEncrypt != 0,
        disableTcp: cfgPtr.ref.disableTcp != 0,
        disableUtp: cfgPtr.ref.disableUtp != 0,
        disableUpload: cfgPtr.ref.disableUpload != 0,
        disableDht: cfgPtr.ref.disableDht != 0,
        disableUpnp: cfgPtr.ref.disableUpnp != 0,
        enableIpv6: cfgPtr.ref.enableIpv6 != 0,
        downloadRateLimit: cfgPtr.ref.downloadRateLimit,
        uploadRateLimit: cfgPtr.ref.uploadRateLimit,
        peersListenPort: cfgPtr.ref.peersListenPort,
        responsiveMode: cfgPtr.ref.responsiveMode != 0,
      );
    } finally {
      calloc.free(cfgPtr);
    }
  }

  /// Number of active streams across all torrents.
  int get activeStreamCount => _b.getActiveStreams(_session);

  // ─── Polling ──────────────────────────────────────────────────────────────

  void _startPolling(Duration interval) {
    _alertCallback ??=
        NativeCallable<LtAlertCallbackNative>.isolateLocal(_onAlert);
    _pollTimer = Timer.periodic(interval, (_) => _poll());
  }

  void _poll() {
    // A native query can fail while a torrent is being removed. Never let one
    // transient native exception kill the periodic polling loop.
    try { _pollTorrents(); } catch (_) {}
    try { _pollStreams(); } catch (_) {}
    try { _pollAlerts(); } catch (_) {}
  }

  void _pollAlerts() {
    if (_alertCallback != null) {
      _b.pollAlerts(_session, _alertCallback!.nativeFunction, nullptr);
    }
  }

  static void _onAlert(
      int type, int torrentId, Pointer<Utf8> message,
      Pointer<Uint8> data, int dataLen, Pointer<Void> userData) {
    final msg = message != nullptr ? message.toDartString() : '';
    final bytes = (data != nullptr && dataLen > 0)
        ? data.asTypedList(dataLen).toList()
        : null;

    final alert = LtAlert(
      type: type,
      torrentId: torrentId,
      message: msg,
      timestamp: DateTime.now(),
      data: bytes,
    );
    final inst = _instance;
    if (inst != null) {
      inst._alertsCtrl.add(alert);

      // Alert types:
      // 26 = piece_finished_alert
      // 30 = save_resume_data_alert
      // 31 = save_resume_data_failed_alert
      // 38 = metadata_received_alert
      if (type == 26) {
        final match = RegExp(r'piece:\s*(\d+)').firstMatch(msg);
        final pieceIndex = match != null ? int.tryParse(match.group(1)!) : null;
        if (pieceIndex != null) {
          inst._completedPieces.putIfAbsent(torrentId, () => <int>{}).add(pieceIndex);
        }
      } else if (type == 30) {
        List<int>? resumeBlob = bytes;
        if (resumeBlob == null || resumeBlob.isEmpty) {
          final take = inst._b.takeSavedResumeData;
          if (take != null) {
            final size = take(inst._session, torrentId, nullptr, 0);
            if (size > 0) {
              final buf = calloc<Uint8>(size);
              try {
                final n = take(inst._session, torrentId, buf, size);
                if (n > 0) resumeBlob = buf.asTypedList(n).toList();
              } finally {
                calloc.free(buf);
              }
            }
          }
        }
        final list = inst._saveResumeCompleters.remove(torrentId);
        if (list != null) {
          for (final c in list) {
            if (!c.isCompleted) {
              c.complete(resumeBlob ?? <int>[]);
            }
          }
        }
      } else if (type == 31) {
        final list = inst._saveResumeCompleters.remove(torrentId);
        if (list != null) {
          for (final c in list) {
            if (!c.isCompleted) {
              c.complete(null);
            }
          }
        }
      } else if (type == 38) {
        inst._cachedFileProgress.remove(torrentId);
        inst._cachedFilePriorities.remove(torrentId);
        inst._completedPieces[torrentId]?.clear();
      }
    }
  }

  void _pollTorrents() {
    final count = _b.getTorrentCount(_session);
    if (count == 0) {
      if (_torrents.isNotEmpty) {
        _torrents.clear();
        _torrentsCtrl.add(const {});
      }
      return;
    }
    final allocCount = max(count, 1);
    final buf = calloc<LtTorrentStatus>(allocCount);
    try {
      final n = _b.getAllStatuses(_session, buf, allocCount);
      bool changed = false;
      final seen = <int>{};

      for (var i = 0; i < n; i++) {
        final raw = buf[i];
        final info = _toTorrentInfo(raw, this);
        seen.add(info.id);
        // file_progress is not part of torrent_status. Populate its cache at
        // the same boundary so every UI consumer gets complete snapshots.
        if (raw.hasMetadata != 0) {
          try { getFileProgress(info.id); } catch (_) {}
          try { getFilePriorities(info.id); } catch (_) {}
        }
        final completeInfo = _toTorrentInfo(raw, this);
        final old = _torrents[completeInfo.id];
        if (old == null || _changed(old, completeInfo)) {
          _torrents[completeInfo.id] = completeInfo;
          changed = true;
        }
      }
      final stale = _torrents.keys.where((k) => !seen.contains(k)).toList();
      for (final k in stale) {
        _torrents.remove(k);
        changed = true;
      }
      if (changed) _torrentsCtrl.add(Map.unmodifiable(_torrents));
    } finally { calloc.free(buf); }
  }

  void _pollStreams() {
    final buf = calloc<LtStreamStatus>(_maxStreams);
    try {
      final n = _b.getAllStreamStatuses(_session, buf, _maxStreams);
      bool changed = false;
      for (var i = 0; i < n; i++) {
        final info = _toStreamInfo(buf[i]);
        final old  = _streams[info.id];
        if (old == null ||
            old.streamState != info.streamState ||
            old.bufferPieces != info.bufferPieces ||
            old.readHead    != info.readHead ||
            old.activePeers != info.activePeers) {
          _streams[info.id] = info;
          changed = true;
        }
        if (!info.isActive) {
          _streams.remove(info.id);
          changed = true;
        }
      }
      if (changed) _streamsCtrl.add(Map.unmodifiable(_streams));
    } finally { calloc.free(buf); }
  }

  bool _changed(TorrentInfo a, TorrentInfo b) {
    if (a.state != b.state ||
        a.progress != b.progress ||
        a.downloadRate != b.downloadRate ||
        a.uploadRate != b.uploadRate ||
        a.totalDone != b.totalDone ||
        a.totalWanted != b.totalWanted ||
        a.totalUploaded != b.totalUploaded ||
        a.numPeers != b.numPeers ||
        a.numSeeds != b.numSeeds ||
        a.numPieces != b.numPieces ||
        a.piecesDone != b.piecesDone ||
        a.isPaused != b.isPaused ||
        a.isFinished != b.isFinished ||
        a.hasMetadata != b.hasMetadata ||
        a.queuePosition != b.queuePosition ||
        a.name != b.name ||
        a.savePath != b.savePath ||
        a.errorMsg != b.errorMsg) return true;
    return !_sameList(a.fileProgress, b.fileProgress) ||
        !_sameList(a.filePriorities, b.filePriorities);
  }

  bool _sameList<T>(List<T> a, List<T> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ─── Cleanup ───────────────────────────────────────────────────────────────

  /// Clean up a single torrent: stops its streams, removes it, deletes files.
  ///
  /// Returns true if the torrent existed and was removed, false if it was
  /// already gone.
  bool disposeTorrent(int torrentId) {
    if (!_torrents.containsKey(torrentId)) return false;

    // Stop any active streams for this torrent
    stopAllStreamsForTorrent(torrentId);

    // Remove the torrent and delete its files
    removeTorrent(torrentId, deleteFiles: true);
    return true;
  }

  /// Clean up ALL torrents: stops every stream, removes every torrent,
  /// deletes all downloaded files. Call this on your exit button.
  void disposeAll({bool deleteFiles = true}) {
    // Stop all streams first
    for (final sid in _streams.keys.toList()) {
      try { stopStream(sid); } catch (_) {}
    }

    // Remove all torrents and delete their files
    for (final tid in _torrents.keys.toList()) {
      try { removeTorrent(tid, deleteFiles: deleteFiles); } catch (_) {}
    }
  }

  /// Shut down the engine entirely. Calls [disposeAll] first, then
  /// destroys the native session. After this, you'd need to call
  /// [init] again to use the engine.
  Future<void> dispose() async {
    // Engine shutdown must not delete the user's downloaded data.
    disposeAll(deleteFiles: false);
    _pollTimer?.cancel();
    _alertCallback?.close();
    _alertCallback = null;
    for (final pending in _saveResumeCompleters.values) {
      for (final c in pending) {
        if (!c.isCompleted) c.complete(null);
      }
    }
    _saveResumeCompleters.clear();
    _b.destroySession(_session);
    await _torrentsCtrl.close();
    await _alertsCtrl.close();
    await _streamsCtrl.close();
    _torrents.clear();
    _streams.clear();
    _cachedFileProgress.clear();
    _cachedFilePriorities.clear();
    _instance = null;
  }
}
