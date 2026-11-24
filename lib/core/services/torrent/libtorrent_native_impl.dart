import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:libtorrent_dart/libtorrent_dart.dart' as lt;

import '../../domain/torrent_models.dart';
import '../../interfaces/i_torrent_native.dart';
import '../../utils/bencode_decoder.dart';
import '../../utils/url_utils.dart';

/// Production [ITorrentNative] implementation backed by `libtorrent_dart`
/// (libtorrent-rasterbar 2.0.11 via Dart Native Assets).
class LibtorrentNativeImpl implements ITorrentNative {
  lt.Session? _session;
  bool _initialized = false;
  bool _disposed = false;
  String _cachedVersion = '2.0.11';
  int _nextExternalId = 1;
  Timer? _pollTimer;

  NativeBtConfig _currentConfig = const NativeBtConfig();

  final Map<int, lt.TorrentHandle> _handlesByExternalId = {};
  final Map<int, int> _nativeToExternalId = {};
  final Map<int, String> _knownInfoHashV1 = {};
  final Map<int, String> _knownInfoHashV2 = {};
  final Map<int, String> _knownNames = {};
  final Map<int, List<lt.TorrentFileEntry>> _cachedFiles = {};
  final Map<int, List<int>> _cachedPriorities = {};

  StreamController<NativeAlertEvent> _alertController =
      StreamController<NativeAlertEvent>.broadcast();
  StreamController<Map<int, NativeTorrentStatus>> _statusController =
      StreamController<Map<int, NativeTorrentStatus>>.broadcast();

  static const Set<String> _streamableExtensions = {
    'mp4',
    'mkv',
    'avi',
    'mov',
    'webm',
    'mp3',
    'flac',
    'm4a',
    'wav',
    'ogg',
    'ts',
    'm4v',
  };

  @override
  bool get isInitialized => _initialized && !_disposed;

  @override
  String get libraryVersion => isInitialized ? _cachedVersion : 'unknown';

  @override
  String? get bridgeDiagnostics =>
      'libtorrent_dart 1.2.0 (libtorrent ${isInitialized ? _cachedVersion : '2.0.11'})';

  @override
  bool get isBridgeCompatible => true;

  @override
  TorrentNativeCapabilities get capabilities =>
      const TorrentNativeCapabilities.v2011();

  @override
  bool get forceRecheckSupported => capabilities.forceRecheck;

  @override
  Stream<NativeAlertEvent> get alertStream => _alertController.stream;

  @override
  Stream<Map<int, NativeTorrentStatus>> get statusStream =>
      _statusController.stream;

  @override
  Future<void> init({
    String listenInterface = '',
    int downloadLimit = 0,
    int uploadLimit = 0,
    Duration pollInterval = const Duration(milliseconds: 600),
    bool fetchTrackers = true,
    String? defaultSavePath,
  }) async {
    if (_initialized && !_disposed) return;
    _disposed = false;
    if (_alertController.isClosed) {
      _alertController = StreamController<NativeAlertEvent>.broadcast();
    }
    if (_statusController.isClosed) {
      _statusController =
          StreamController<Map<int, NativeTorrentStatus>>.broadcast();
    }

    final session = lt.createSession();
    _session = session;
    try {
      _cachedVersion = lt.getLibtorrentVersion();
    } catch (_) {
      _cachedVersion = '2.0.11';
    }

    try {
      session.setIntSetting(
        lt.LibtorrentSettingsTag.alertMask,
        lt.LibtorrentAlertCategory.all,
      );
    } catch (e) {
      debugPrint('[LibtorrentNative] Failed to set alertMask: $e');
    }

    if (listenInterface.isNotEmpty) {
      try {
        session.setStringSetting(
          lt.LibtorrentSettingsTag.listenInterfaces,
          listenInterface,
        );
      } catch (e) {
        debugPrint('[LibtorrentNative] Failed to set listenInterfaces: $e');
      }
    }

    _initialized = true;

    configureSession(
      NativeBtConfig(
        downloadRateLimit: downloadLimit > 0 ? downloadLimit : 0,
        uploadRateLimit: uploadLimit > 0 ? uploadLimit : 0,
      ),
    );

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollTick());
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _initialized = false;

    _pollTimer?.cancel();
    _pollTimer = null;

    final session = _session;
    _session = null;
    if (session != null) {
      try {
        session.close();
      } catch (e) {
        debugPrint('[LibtorrentNative] Session close warning: $e');
      }
    }

    _handlesByExternalId.clear();
    _nativeToExternalId.clear();
    _knownInfoHashV1.clear();
    _knownInfoHashV2.clear();
    _knownNames.clear();
    _cachedFiles.clear();
    _cachedPriorities.clear();

    if (!_alertController.isClosed) {
      await _alertController.close();
    }
    if (!_statusController.isClosed) {
      await _statusController.close();
    }
  }

  void _pollTick() {
    if (!isInitialized) return;
    _drainAlerts();
    final statuses = getAllTorrentStatuses();
    if (!_statusController.isClosed && statuses.isNotEmpty) {
      _statusController.add(statuses);
    }
  }

  void _drainAlerts() {
    final session = _session;
    if (session == null) return;
    for (var i = 0; i < 128; i++) {
      lt.AlertInfo? alert;
      try {
        alert = session.popAlertInfo();
      } catch (_) {
        break;
      }
      if (alert == null) break;

      final externalId = alert.torrentId != null
          ? (_nativeToExternalId[alert.torrentId!] ?? -1)
          : -1;
      final type = _mapAlertType(alert);
      final event = NativeAlertEvent(
        type: type,
        alertCode: alert.type,
        torrentId: externalId,
        message: alert.message,
        timestamp: DateTime.now(),
        pieceIndex: alert.pieceIndex,
        error: type == TorrentAlertType.torrentError ||
                type == TorrentAlertType.trackerError ||
                type == TorrentAlertType.fastresumeRejected ||
                type == TorrentAlertType.saveResumeDataFailed
            ? alert.message
            : null,
      );
      if (!_alertController.isClosed) {
        _alertController.add(event);
      }
    }
  }

  TorrentAlertType _mapAlertType(lt.AlertInfo alert) {
    final what = alert.what.toLowerCase().replaceAll('_alert', '').trim();
    switch (what) {
      case 'metadata_received':
        return TorrentAlertType.metadataReceived;
      case 'torrent_paused':
        return TorrentAlertType.torrentPaused;
      case 'torrent_resumed':
        return TorrentAlertType.torrentResumed;
      case 'piece_finished':
        return TorrentAlertType.pieceFinished;
      case 'save_resume_data':
        return TorrentAlertType.saveResumeDataCompleted;
      case 'save_resume_data_failed':
        return TorrentAlertType.saveResumeDataFailed;
      case 'tracker_reply':
        return TorrentAlertType.trackerReply;
      case 'tracker_error':
        return TorrentAlertType.trackerError;
      case 'fastresume_rejected':
        return TorrentAlertType.fastresumeRejected;
      case 'torrent_error':
        return TorrentAlertType.torrentError;
      default:
        return TorrentAlertType.fromNativeType(alert.type);
    }
  }

  int _registerHandle(
    lt.TorrentHandle handle, {
    String name = '',
    String infoHashV1 = '',
    String infoHashV2 = '',
  }) {
    final existingExternalId = _nativeToExternalId[handle.id];
    if (existingExternalId != null) {
      _handlesByExternalId[existingExternalId] = handle;
      if (name.isNotEmpty) _knownNames[existingExternalId] = name;
      if (infoHashV1.isNotEmpty) {
        _knownInfoHashV1[existingExternalId] = infoHashV1.toLowerCase();
      }
      if (infoHashV2.isNotEmpty) {
        _knownInfoHashV2[existingExternalId] = infoHashV2.toLowerCase();
      }
      return existingExternalId;
    }

    final externalId = _nextExternalId++;
    _handlesByExternalId[externalId] = handle;
    _nativeToExternalId[handle.id] = externalId;
    if (name.isNotEmpty) _knownNames[externalId] = name;
    if (infoHashV1.isNotEmpty) {
      _knownInfoHashV1[externalId] = infoHashV1.toLowerCase();
    }
    if (infoHashV2.isNotEmpty) {
      _knownInfoHashV2[externalId] = infoHashV2.toLowerCase();
    }
    return externalId;
  }

  @override
  int addMagnet(
    String magnetUri,
    String savePath, {
    bool streamOnly = false,
    List<int>? resumeData,
  }) {
    final session = _session;
    if (!isInitialized || session == null) return -1;

    try {
      Directory(savePath).createSync(recursive: true);
    } catch (_) {}

    var initialName = '';
    var v1 = '';
    var v2 = '';
    final parsed = parseMagnetUrl(magnetUri);
    initialName = parsed['name'] ?? '';
    v1 = parsed['infoHashV1'] ?? parsed['infoHash'] ?? '';
    v2 = parsed['infoHashV2'] ?? '';
    if (v1.isEmpty || initialName.isEmpty) {
      try {
        final ltMeta = lt.parseMagnetUri(magnetUri);
        if (v1.isEmpty && ltMeta.infohashHex.isNotEmpty) {
          v1 = ltMeta.infohashHex;
        }
        if (initialName.isEmpty && ltMeta.name.isNotEmpty) {
          initialName = ltMeta.name;
        }
      } catch (_) {}
    }

    lt.TorrentHandle? handle;
    if (resumeData != null && resumeData.isNotEmpty) {
      try {
        final resumeBytes = Uint8List.fromList(resumeData);
        handle = session.addTorrentFromTags([
          lt.LibtorrentTagItem.stringValue(
            lt.LibtorrentTag.torMagnetLink,
            magnetUri,
          ),
          lt.LibtorrentTagItem.stringValue(
            lt.LibtorrentTag.torSavePath,
            savePath,
          ),
          lt.LibtorrentTagItem.bytesValue(
            lt.LibtorrentTag.torResumeData,
            resumeBytes,
          ),
          lt.LibtorrentTagItem.intValue(
            lt.LibtorrentTag.torResumeDataSize,
            resumeBytes.length,
          ),
          lt.LibtorrentTagItem.intValue(lt.LibtorrentTag.torAutoManaged, 0),
          lt.LibtorrentTagItem.intValue(lt.LibtorrentTag.torPaused, 0),
        ]);
      } catch (e) {
        debugPrint(
          '[LibtorrentNative] addMagnet with resumeData failed, falling back: $e',
        );
      }
    }

    handle ??= session.addMagnet(magnetUri: magnetUri, savePath: savePath);

    try {
      handle.unsetFlags(lt.LibtorrentTorrentFlags.autoManaged);
      if (streamOnly) {
        handle.setSequentialDownload(true);
      }
      handle.resume();
      handle.forceReannounce();
      if (!_currentConfig.disableDht) {
        handle.forceDhtAnnounce();
      }
      handle.forceLsdAnnounce();
    } catch (_) {}

    return _registerHandle(
      handle,
      name: initialName,
      infoHashV1: v1,
      infoHashV2: v2,
    );
  }

  @override
  int addTorrentFile(
    String filePath,
    String savePath, {
    bool streamOnly = false,
    List<int>? resumeData,
  }) {
    final session = _session;
    if (!isInitialized || session == null) return -1;

    try {
      Directory(savePath).createSync(recursive: true);
    } catch (_) {}

    var initialName = '';
    var v1 = '';
    var v2 = '';
    try {
      final bytes = File(filePath).readAsBytesSync();
      final meta = BencodeDecoder.parseTorrentBytes(bytes);
      if (meta != null) {
        initialName = (meta['name'] as String?) ?? '';
        v1 = (meta['infoHashV1'] as String?) ??
            (meta['infoHash'] as String?) ??
            '';
        v2 = (meta['infoHashV2'] as String?) ?? '';
      }
    } catch (_) {}
    if (v1.isEmpty || initialName.isEmpty) {
      try {
        final ltFileInfo = lt.loadTorrentFile(filePath);
        if (v1.isEmpty && ltFileInfo.infohashHex.isNotEmpty) {
          v1 = ltFileInfo.infohashHex;
        }
        if (initialName.isEmpty && ltFileInfo.name.isNotEmpty) {
          initialName = ltFileInfo.name;
        }
      } catch (_) {}
    }

    lt.TorrentHandle? handle;
    if (resumeData != null && resumeData.isNotEmpty) {
      try {
        final resumeBytes = Uint8List.fromList(resumeData);
        handle = session.addTorrentFromTags([
          lt.LibtorrentTagItem.stringValue(
            lt.LibtorrentTag.torFilename,
            filePath,
          ),
          lt.LibtorrentTagItem.stringValue(
            lt.LibtorrentTag.torSavePath,
            savePath,
          ),
          lt.LibtorrentTagItem.bytesValue(
            lt.LibtorrentTag.torResumeData,
            resumeBytes,
          ),
          lt.LibtorrentTagItem.intValue(
            lt.LibtorrentTag.torResumeDataSize,
            resumeBytes.length,
          ),
          lt.LibtorrentTagItem.intValue(lt.LibtorrentTag.torAutoManaged, 0),
          lt.LibtorrentTagItem.intValue(lt.LibtorrentTag.torPaused, 0),
        ]);
      } catch (e) {
        debugPrint(
          '[LibtorrentNative] addTorrentFile with resumeData failed, falling back: $e',
        );
      }
    }

    handle ??=
        session.addTorrentFile(torrentPath: filePath, savePath: savePath);

    try {
      handle.unsetFlags(lt.LibtorrentTorrentFlags.autoManaged);
      if (streamOnly) {
        handle.setSequentialDownload(true);
      }
      handle.resume();
      handle.forceReannounce();
      if (!_currentConfig.disableDht) {
        handle.forceDhtAnnounce();
      }
      handle.forceLsdAnnounce();
    } catch (_) {}

    return _registerHandle(
      handle,
      name: initialName,
      infoHashV1: v1,
      infoHashV2: v2,
    );
  }

  @override
  void removeTorrent(int id, {bool deleteFiles = false}) {
    if (id < 0 || !isInitialized) return;
    final handle = _handlesByExternalId.remove(id);
    _knownInfoHashV1.remove(id);
    _knownInfoHashV2.remove(id);
    _knownNames.remove(id);
    _cachedFiles.remove(id);
    _cachedPriorities.remove(id);
    if (handle == null) return;
    _nativeToExternalId.remove(handle.id);

    try {
      _session?.removeTorrent(
        handle,
        deleteFiles: deleteFiles,
        deletePartfile: deleteFiles,
      );
    } catch (e) {
      debugPrint('[LibtorrentNative] removeTorrent($id) failed: $e');
    }
  }

  @override
  Future<void> pauseTorrent(int id, {bool graceful = true}) async {
    if (id < 0 || !isInitialized) return;
    final handle = _handlesByExternalId[id];
    if (handle == null) return;

    try {
      handle.unsetFlags(lt.LibtorrentTorrentFlags.autoManaged);
      handle.pause();
      if (graceful) {
        try {
          handle.flushCache();
        } catch (_) {}
      }
      _drainAlerts();
      final updated = getTorrentStatus(id);
      if (updated != null && !_statusController.isClosed) {
        _statusController.add({id: updated});
      }
    } catch (e) {
      debugPrint('[LibtorrentNative] pauseTorrent($id) failed: $e');
    }
  }

  @override
  Future<void> resumeTorrent(int id) async {
    if (id < 0 || !isInitialized) return;
    final handle = _handlesByExternalId[id];
    if (handle == null) return;

    try {
      try {
        handle.clearError();
      } catch (_) {}
      handle.unsetFlags(lt.LibtorrentTorrentFlags.autoManaged);
      handle.resume();
      try {
        handle.forceReannounce();
        if (!_currentConfig.disableDht) {
          handle.forceDhtAnnounce();
        }
        handle.forceLsdAnnounce();
      } catch (_) {}
      _drainAlerts();
    } catch (e) {
      debugPrint('[LibtorrentNative] resumeTorrent($id) failed: $e');
    }
  }

  @override
  void recheckTorrent(int id) {
    if (id < 0 || !isInitialized) return;
    final handle = _handlesByExternalId[id];
    if (handle == null) return;
    try {
      handle.forceRecheck();
    } catch (e) {
      debugPrint('[LibtorrentNative] recheckTorrent($id) failed: $e');
    }
  }

  int _mapDomainState(int ltState, {required bool hasError}) {
    if (hasError) return -2;
    switch (ltState) {
      case lt.LibtorrentTorrentState.queuedForChecking:
      case lt.LibtorrentTorrentState.checkingFiles:
        return 0; // checkingFiles
      case lt.LibtorrentTorrentState.downloadingMetadata:
        return 1; // downloadingMetadata
      case lt.LibtorrentTorrentState.downloading:
        return 2; // downloading
      case lt.LibtorrentTorrentState.finished:
        return 3; // finished
      case lt.LibtorrentTorrentState.seeding:
        return 4; // seeding
      case lt.LibtorrentTorrentState.allocating:
        return 5; // allocating
      case lt.LibtorrentTorrentState.checkingResumeData:
        return 6; // checkingResume
      default:
        return -1;
    }
  }

  String _mapStateLabel(
    int ltState, {
    required bool isPaused,
    required bool hasError,
  }) {
    if (hasError) return 'Error';
    if (isPaused) return 'Paused';
    switch (ltState) {
      case lt.LibtorrentTorrentState.queuedForChecking:
        return 'Queued';
      case lt.LibtorrentTorrentState.checkingFiles:
        return 'Checking files';
      case lt.LibtorrentTorrentState.downloadingMetadata:
        return 'Downloading metadata';
      case lt.LibtorrentTorrentState.downloading:
        return 'Downloading';
      case lt.LibtorrentTorrentState.finished:
        return 'Finished';
      case lt.LibtorrentTorrentState.seeding:
        return 'Seeding';
      case lt.LibtorrentTorrentState.allocating:
        return 'Allocating';
      case lt.LibtorrentTorrentState.checkingResumeData:
        return 'Checking resume data';
      default:
        return 'Unknown';
    }
  }

  @override
  NativeTorrentStatus? getTorrentStatus(int id) {
    if (id < 0 || !isInitialized) return null;
    final handle = _handlesByExternalId[id];
    if (handle == null) return null;

    try {
      final st = handle.getStatus();
      var flags = 0;
      try {
        flags = handle.flags;
      } catch (_) {}
      final isPaused =
          st.paused || ((flags & lt.LibtorrentTorrentFlags.paused) != 0);

      var hasMetadata = false;
      var files = _cachedFiles[id];
      if (files != null && files.isNotEmpty) {
        hasMetadata = true;
      } else {
        try {
          files = handle.getFiles();
          if (files.isNotEmpty) {
            _cachedFiles[id] = files;
            hasMetadata = true;
          }
        } catch (_) {}
      }
      if (!hasMetadata && st.numPieces > 0) {
        hasMetadata = true;
      }

      List<int> fileProgress = const [];
      List<int> filePriorities = _cachedPriorities[id] ?? const [];
      List<bool> pieces = const [];
      var piecesDone = 0;
      var numPieces = st.numPieces;

      if (hasMetadata) {
        try {
          fileProgress = handle.getFileProgress();
        } catch (_) {}
        try {
          filePriorities = handle.getFilePriorities();
          if (filePriorities.isNotEmpty) {
            _cachedPriorities[id] = filePriorities;
          }
        } catch (_) {}
        try {
          final pieceBytes = handle.getPieces();
          if (pieceBytes.isNotEmpty) {
            pieces = pieceBytes.map((b) => b != 0).toList(growable: false);
            for (final have in pieces) {
              if (have) piecesDone++;
            }
            if (numPieces <= 0) numPieces = pieces.length;
          }
        } catch (_) {}
      }

      var name = _knownNames[id] ?? '';
      if (files != null && files.isNotEmpty) {
        final firstPath = files.first.path;
        if (files.length == 1) {
          name = _basename(firstPath);
        } else {
          final norm = firstPath.replaceAll('\\', '/');
          final slash = norm.indexOf('/');
          name = slash > 0 ? norm.substring(0, slash) : _basename(norm);
        }
        if (name.isNotEmpty) _knownNames[id] = name;
      }

      var savePath = '';
      try {
        savePath = handle.savePath;
      } catch (_) {}

      final hasError = st.error.isNotEmpty;
      final isFinished = st.state == lt.LibtorrentTorrentState.finished ||
          st.state == lt.LibtorrentTorrentState.seeding ||
          (hasMetadata &&
              st.totalWanted > 0 &&
              st.totalWantedDone >= st.totalWanted &&
              st.state != lt.LibtorrentTorrentState.checkingFiles &&
              st.state != lt.LibtorrentTorrentState.checkingResumeData);

      final dlRate = st.downloadPayloadRate > 0
          ? st.downloadPayloadRate.round()
          : st.downloadRate.round();
      final ulRate = st.uploadPayloadRate > 0
          ? st.uploadPayloadRate.round()
          : st.uploadRate.round();

      var queuePos = -1;
      try {
        queuePos = handle.queuePosition;
      } catch (_) {}

      final clampedWantedDone =
          st.totalWanted > 0 && st.totalWantedDone > st.totalWanted
              ? st.totalWanted
              : st.totalWantedDone;

      return NativeTorrentStatus(
        id: id,
        name: name,
        savePath: savePath,
        errorMsg: st.error,
        state: _mapDomainState(st.state, hasError: hasError),
        stateLabel: _mapStateLabel(
          st.state,
          isPaused: isPaused,
          hasError: hasError,
        ),
        progress: st.progress.clamp(0.0, 1.0),
        downloadRate: isPaused ? 0 : dlRate,
        uploadRate: isPaused ? 0 : ulRate,
        totalDone: st.totalDone,
        totalWanted: st.totalWanted,
        totalWantedDone: clampedWantedDone,
        totalUploaded:
            st.totalPayloadUpload > 0 ? st.totalPayloadUpload : st.totalUpload,
        numPeers: st.numPeers < 0 ? 0 : st.numPeers,
        numSeeds: st.numSeeds < 0 ? 0 : st.numSeeds,
        numComplete: st.numComplete >= 0 ? st.numComplete : null,
        numIncomplete: st.numIncomplete >= 0 ? st.numIncomplete : null,
        numPieces: numPieces,
        piecesDone: piecesDone,
        pieces: pieces,
        isPaused: isPaused,
        isFinished: isFinished,
        hasMetadata: hasMetadata,
        queuePosition: queuePos,
        fileProgress: fileProgress,
        filePriorities: filePriorities,
        infoHashV1: _knownInfoHashV1[id] ?? '',
        infoHashV2: _knownInfoHashV2[id] ?? '',
        distributedCopies: st.distributedCopies,
        activeTime: st.activeTime,
        seedingTime: st.seedingTime,
      );
    } catch (e) {
      debugPrint('[LibtorrentNative] getTorrentStatus($id) failed: $e');
      return null;
    }
  }

  @override
  Map<int, NativeTorrentStatus> getAllTorrentStatuses() {
    if (!isInitialized || _handlesByExternalId.isEmpty) return const {};
    final result = <int, NativeTorrentStatus>{};
    for (final id in List<int>.from(_handlesByExternalId.keys)) {
      final status = getTorrentStatus(id);
      if (status != null) {
        result[id] = status;
      }
    }
    return result;
  }

  String _basename(String path) {
    final norm = path.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    return idx >= 0 ? norm.substring(idx + 1) : norm;
  }

  bool _isStreamablePath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    return _streamableExtensions
        .contains(path.substring(dot + 1).toLowerCase());
  }

  @override
  List<NativeFileInfo> getFiles(int id) {
    if (id < 0 || !isInitialized) return const [];
    final handle = _handlesByExternalId[id];
    if (handle == null) return const [];

    List<lt.TorrentFileEntry>? entries = _cachedFiles[id];
    if (entries == null || entries.isEmpty) {
      try {
        entries = handle.getFiles();
        if (entries.isNotEmpty) {
          _cachedFiles[id] = entries;
        }
      } catch (_) {
        entries = _cachedFiles[id];
      }
    }
    if (entries == null || entries.isEmpty) return const [];

    return entries
        .map(
          (entry) => NativeFileInfo(
            index: entry.index,
            name: _basename(entry.path),
            path: entry.path,
            size: entry.size,
            isStreamable: _isStreamablePath(entry.path),
          ),
        )
        .toList(growable: false);
  }

  @override
  void setFilePriorities(int id, List<int> priorities) {
    if (id < 0 || !isInitialized) return;
    final handle = _handlesByExternalId[id];
    if (handle == null) return;
    try {
      handle.prioritizeFiles(priorities);
      _cachedPriorities[id] = List<int>.from(priorities);
    } catch (e) {
      debugPrint('[LibtorrentNative] setFilePriorities($id) failed: $e');
    }
  }

  @override
  List<int> getFilePriorities(int id) {
    if (id < 0 || !isInitialized) return const [];
    final handle = _handlesByExternalId[id];
    if (handle == null) return const [];
    try {
      final result = handle.getFilePriorities();
      _cachedPriorities[id] = result;
      return result;
    } catch (_) {
      return _cachedPriorities[id] ?? const [];
    }
  }

  @override
  List<int> getFileProgress(int id) {
    if (id < 0 || !isInitialized) return const [];
    final handle = _handlesByExternalId[id];
    if (handle == null) return const [];
    try {
      return handle.getFileProgress();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<PeerConnectionQuality>> getPeers(int torrentId) async {
    if (torrentId < 0 || !isInitialized) return const [];
    final handle = _handlesByExternalId[torrentId];
    if (handle == null) return const [];

    try {
      final peers = handle.getPeerInfo();
      return peers
          .map(
            (p) => PeerConnectionQuality(
              ip: p.ip,
              port: p.port,
              client: p.client,
              downloadSpeed:
                  (p.payloadDownSpeed > 0 ? p.payloadDownSpeed : p.downSpeed)
                      .toDouble(),
              uploadSpeed: (p.payloadUpSpeed > 0 ? p.payloadUpSpeed : p.upSpeed)
                  .toDouble(),
              progress: 0.0,
              // libtorrent peer_info::seed = 1 << 9 (0x200)
              isSeed: (p.flags & 0x200) != 0,
              // rc4_encrypted (1 << 18) | plaintext_encrypted (1 << 17)
              isEncrypted: (p.flags & 0x60000) != 0,
              isOutgoing: (p.flags & 0x40) == 0,
            ),
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<int>?> saveResumeData(
    int id, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (id < 0 || !isInitialized) return null;
    final handle = _handlesByExternalId[id];
    if (handle == null) return null;

    try {
      // flags = 3 => flush_disk_cache (1) | save_info_dict (2)
      final data = handle.getResumeData(flags: 3);
      return data.isEmpty ? null : data;
    } catch (e) {
      debugPrint('[LibtorrentNative] saveResumeData($id) failed: $e');
      return null;
    }
  }

  @override
  bool loadResumeData(int id, List<int> data) {
    // libtorrent 2.x applies resume data at add_torrent time via
    // addMagnet(..., resumeData:) or addTorrentFile(..., resumeData:).
    return false;
  }

  @override
  void setDownloadLimit(int bps) {
    final safeBps = bps < 0 ? 0 : bps;
    _currentConfig = NativeBtConfig(
      cacheSize: _currentConfig.cacheSize,
      readerReadAhead: _currentConfig.readerReadAhead,
      preloadCache: _currentConfig.preloadCache,
      connectionsLimit: _currentConfig.connectionsLimit,
      torrentDisconnectTimeout: _currentConfig.torrentDisconnectTimeout,
      forceEncrypt: _currentConfig.forceEncrypt,
      disableTcp: _currentConfig.disableTcp,
      disableUtp: _currentConfig.disableUtp,
      disableUpload: _currentConfig.disableUpload,
      disableDht: _currentConfig.disableDht,
      disableUpnp: _currentConfig.disableUpnp,
      enableIpv6: _currentConfig.enableIpv6,
      downloadRateLimit: safeBps,
      uploadRateLimit: _currentConfig.uploadRateLimit,
      peersListenPort: _currentConfig.peersListenPort,
      responsiveMode: _currentConfig.responsiveMode,
      dhtBootstrapNodes: _currentConfig.dhtBootstrapNodes,
    );
    if (!isInitialized) return;
    try {
      _session!.setDownloadRateLimit(safeBps);
    } catch (e) {
      debugPrint('[LibtorrentNative] setDownloadLimit($safeBps) failed: $e');
    }
  }

  @override
  void setUploadLimit(int bps) {
    final safeBps = bps < 0 ? 0 : bps;
    _currentConfig = NativeBtConfig(
      cacheSize: _currentConfig.cacheSize,
      readerReadAhead: _currentConfig.readerReadAhead,
      preloadCache: _currentConfig.preloadCache,
      connectionsLimit: _currentConfig.connectionsLimit,
      torrentDisconnectTimeout: _currentConfig.torrentDisconnectTimeout,
      forceEncrypt: _currentConfig.forceEncrypt,
      disableTcp: _currentConfig.disableTcp,
      disableUtp: _currentConfig.disableUtp,
      disableUpload: _currentConfig.disableUpload,
      disableDht: _currentConfig.disableDht,
      disableUpnp: _currentConfig.disableUpnp,
      enableIpv6: _currentConfig.enableIpv6,
      downloadRateLimit: _currentConfig.downloadRateLimit,
      uploadRateLimit: safeBps,
      peersListenPort: _currentConfig.peersListenPort,
      responsiveMode: _currentConfig.responsiveMode,
      dhtBootstrapNodes: _currentConfig.dhtBootstrapNodes,
    );
    if (!isInitialized) return;
    try {
      _session!.setUploadRateLimit(safeBps);
    } catch (e) {
      debugPrint('[LibtorrentNative] setUploadLimit($safeBps) failed: $e');
    }
  }

  @override
  void configureSession(NativeBtConfig config) {
    _currentConfig = config;
    final session = _session;
    if (!isInitialized || session == null) return;

    try {
      session.applyConfig(
        lt.SessionConfig(
          uploadRateLimit: config.disableUpload
              ? 1
              : (config.uploadRateLimit > 0 ? config.uploadRateLimit : 0),
          downloadRateLimit:
              config.downloadRateLimit > 0 ? config.downloadRateLimit : 0,
          connectionsLimit: config.connectionsLimit,
          activeDownloads: 64,
          activeSeeds: 64,
          activeLimit: 500,
          torrentPort:
              config.peersListenPort > 0 ? config.peersListenPort : null,
          outgoingEncryptionPolicy: config.forceEncrypt
              ? lt.LibtorrentEncryptionPolicy.forced
              : lt.LibtorrentEncryptionPolicy.enabled,
          incomingEncryptionPolicy: config.forceEncrypt
              ? lt.LibtorrentEncryptionPolicy.forced
              : lt.LibtorrentEncryptionPolicy.enabled,
          allowedEncryptionLevel: lt.LibtorrentEncryptionLevel.both,
          enableIncomingTcp: !config.disableTcp,
          enableOutgoingTcp: !config.disableTcp,
          enableIncomingUtp: !config.disableUtp,
          enableOutgoingUtp: !config.disableUtp,
        ),
      );

      session.setUpnpEnabled(!config.disableUpnp);
      session.setNatPmpEnabled(!config.disableUpnp);
      session.setLsdEnabled(true);
      session.setDhtEnabled(!config.disableDht);

      if (!config.disableDht) {
        try {
          session.startDht();
        } catch (_) {}
        for (final node in config.dhtBootstrapNodes) {
          final colonIdx = node.lastIndexOf(':');
          if (colonIdx <= 0 || colonIdx == node.length - 1) continue;
          final host = node.substring(0, colonIdx).trim();
          final port = int.tryParse(node.substring(colonIdx + 1).trim());
          if (host.isNotEmpty && port != null && port > 0) {
            try {
              session.addDhtNode(hostname: host, port: port);
            } catch (_) {}
          }
        }
      } else {
        try {
          session.stopDht();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[LibtorrentNative] configureSession failed: $e');
    }
  }

  @override
  NativeBtConfig getDefaultConfig() => const NativeBtConfig();

  @override
  List<NativeTrackerInfo> getTrackers(int id) {
    if (id < 0 || !isInitialized) return const [];
    final handle = _handlesByExternalId[id];
    if (handle == null) return const [];
    try {
      final urls = handle.getTrackers();
      return urls
          .asMap()
          .entries
          .map(
            (e) => NativeTrackerInfo(
              url: e.value,
              tier: e.key,
              status: 'active',
              seeds: 0,
              peers: 0,
              message: '',
            ),
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  @override
  void addTracker(int id, String trackerUrl, {int tier = 0}) {
    if (id < 0 || !isInitialized || trackerUrl.trim().isEmpty) return;
    final handle = _handlesByExternalId[id];
    if (handle == null) return;
    try {
      handle.addTracker(trackerUrl.trim(), tier: tier);
    } catch (e) {
      debugPrint('[LibtorrentNative] addTracker($id) failed: $e');
    }
  }

  @override
  void removeTracker(int id, String trackerUrl) {
    if (id < 0 || !isInitialized) return;
    final handle = _handlesByExternalId[id];
    if (handle == null) return;
    try {
      final target = trackerUrl.trim();
      final remaining = handle
          .getTrackers()
          .where((url) => url.trim() != target)
          .toList(growable: false);
      handle.replaceTrackers(remaining);
    } catch (e) {
      debugPrint('[LibtorrentNative] removeTracker($id) failed: $e');
    }
  }

  @override
  void announceNow(int id) {
    if (id < 0 || !isInitialized) return;
    final handle = _handlesByExternalId[id];
    if (handle == null) return;
    try {
      handle.forceReannounce();
    } catch (_) {}
    if (!_currentConfig.disableDht) {
      try {
        handle.forceDhtAnnounce();
      } catch (_) {}
    }
    try {
      handle.forceLsdAnnounce();
    } catch (_) {}
  }

  @override
  void setSequentialDownload(int id, bool enabled) {
    if (id < 0 || !isInitialized) return;
    final handle = _handlesByExternalId[id];
    if (handle == null) return;
    try {
      handle.setSequentialDownload(enabled);
    } catch (e) {
      debugPrint('[LibtorrentNative] setSequentialDownload($id) failed: $e');
    }
  }

  @override
  void setSuperSeeding(int id, bool enabled) {
    if (id < 0 || !isInitialized) return;
    final handle = _handlesByExternalId[id];
    if (handle == null) return;
    try {
      handle.setSuperSeeding(enabled);
    } catch (e) {
      debugPrint('[LibtorrentNative] setSuperSeeding($id) failed: $e');
    }
  }

  @override
  void setPieceDeadline(int id, int pieceIndex, int deadlineMs) {
    if (id < 0 || !isInitialized) return;
    final handle = _handlesByExternalId[id];
    if (handle == null) return;
    try {
      handle.setPieceDeadline(pieceIndex, deadlineMs);
    } catch (e) {
      debugPrint('[LibtorrentNative] setPieceDeadline($id) failed: $e');
    }
  }

  @override
  Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  }) async {
    if (sourcePath.isEmpty || outputPath.isEmpty) return null;
    if (!File(sourcePath).existsSync() && !Directory(sourcePath).existsSync()) {
      return null;
    }
    try {
      final outDir = File(outputPath).parent;
      if (!outDir.existsSync()) {
        outDir.createSync(recursive: true);
      }
      lt.createTorrentFile(
        sourcePath: sourcePath,
        outputPath: outputPath,
        trackerUrl: trackers.isNotEmpty ? trackers.first : null,
        pieceSize: pieceSize,
      );
      return File(outputPath).existsSync() ? outputPath : null;
    } catch (e) {
      debugPrint('[LibtorrentNative] createTorrent failed: $e');
      return null;
    }
  }

  @override
  Future<bool> loadIpFilter(String filePath) async => false;

  @override
  Future<void> setProxy({
    required String host,
    required int port,
    required int type,
    String? username,
    String? password,
  }) async {
    final session = _session;
    if (!isInitialized || session == null) return;

    final hasAuth = (username != null && username.isNotEmpty) ||
        (password != null && password.isNotEmpty);
    final int ltType;
    switch (type) {
      case 1: // ProxyType.socks5
        ltType = hasAuth
            ? lt.LibtorrentProxyType.socks5Password
            : lt.LibtorrentProxyType.socks5;
      case 2: // ProxyType.http
        ltType = hasAuth
            ? lt.LibtorrentProxyType.httpPassword
            : lt.LibtorrentProxyType.http;
      default: // ProxyType.none
        ltType = lt.LibtorrentProxyType.none;
    }

    try {
      session.setProxy(
        lt.ProxySetting(
          hostname: host,
          port: port,
          username: username ?? '',
          password: password ?? '',
          type: ltType,
        ),
      );
    } catch (e) {
      debugPrint('[LibtorrentNative] setProxy failed: $e');
    }
  }

  @override
  Future<void> setSslCertificate({
    required String certPath,
    required String privateKeyPath,
    String? dhParamsPath,
  }) async {
    // Not exposed by libtorrent_dart 1.2.0.
  }

  @override
  void addWebSeed(int id, String url) {
    if (id < 0 || !isInitialized || url.trim().isEmpty) return;
    final handle = _handlesByExternalId[id];
    if (handle == null) return;
    try {
      handle.addUrlSeed(url.trim());
    } catch (e) {
      debugPrint('[LibtorrentNative] addWebSeed($id) failed: $e');
    }
  }

  @override
  void removeWebSeed(int id, String url) {
    if (id < 0 || !isInitialized) return;
    final handle = _handlesByExternalId[id];
    if (handle == null) return;
    try {
      handle.removeUrlSeed(url.trim());
    } catch (e) {
      debugPrint('[LibtorrentNative] removeWebSeed($id) failed: $e');
    }
  }

  @override
  List<String> getWebSeeds(int id) {
    if (id < 0 || !isInitialized) return const [];
    final handle = _handlesByExternalId[id];
    if (handle == null) return const [];
    try {
      return handle.getUrlSeeds();
    } catch (_) {
      return const [];
    }
  }
}
