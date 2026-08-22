// FFI bindings mirroring torrent_bridge.h — cross-platform library loader.

import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'package:ffi/ffi.dart';

// ─── Opaque native types ──────────────────────────────────────────────────────
final class LtSessionOpaque extends Opaque {}

// ─── lt_torrent_status ────────────────────────────────────────────────────────
final class LtTorrentStatus extends Struct {
  @Int64()   external int id;
  @Array(512)  external Array<Char> name;
  @Array(1024) external Array<Char> savePath;
  @Array(256)  external Array<Char> errorMsg;
  @Int32()   external int state;
  @Float()   external double progress;
  @Int32()   external int downloadRate;
  @Int32()   external int uploadRate;
  @Int64()   external int totalWantedDone;   // Renamed from totalDone
  @Int64()   external int totalWanted;
  @Int64()   external int totalUploaded;
  @Int32()   external int numPeers;
  @Int32()   external int numSeeds;
  @Int32()   external int numComplete;       // Swarm seeds (-1 = unknown)
  @Int32()   external int numIncomplete;     // Swarm peers (-1 = unknown)
  @Int32()   external int numPieces;
  @Int32()   external int piecesDone;
  @Int32()   external int isPaused;
  @Int32()   external int isFinished;
  @Int32()   external int hasMetadata;
  @Int32()   external int queuePosition;
}

// Add ABI guard
bool verifyStatusStructContract() {
  final ok = sizeOf<LtTorrentStatus>() == 1880;
  assert(ok, 'LtTorrentStatus drift: expected 1880 bytes');
  return ok;
}

// ─── lt_file_info ─────────────────────────────────────────────────────────────
final class LtFileInfo extends Struct {
  @Int32()     external int index;
  @Array(512)  external Array<Char> name;
  @Array(1024) external Array<Char> path;
  @Int64()     external int size;
  @Int32()     external int isStreamable;
}

// ─── lt_tracker_info ──────────────────────────────────────────────────────────
final class LtTrackerInfo extends Struct {
  @Array(512)  external Array<Char> url;
  @Int32()      external int tier;
  @Int32()      external int status; // 0 working, 1 updating, 2 notWorking, 3 disabled
  @Int32()      external int seeds;
  @Int32()      external int peers;
  @Int32()      external int downloaded;
  @Array(256)  external Array<Char> message;
  @Int32()      external int nextAnnounceSeconds;
}

// ─── lt_stream_status ─────────────────────────────────────────────────────────
final class LtStreamStatus extends Struct {
  @Int64()    external int id;
  @Int64()    external int torrentId;
  @Int32()    external int fileIndex;
  @Array(256) external Array<Char> url;
  @Int64()    external int fileSize;
  @Int64()    external int readHead;
  @Int32()    external int streamState;
  @Float()    external double bufferSeconds;
  @Int32()    external int bufferPieces;
  @Int32()    external int readaheadWindow;
  @Int32()    external int activePeers;
  @Int32()    external int downloadRate;
}

// ─── Alert callback ───────────────────────────────────────────────────────────
typedef LtAlertCallbackNative = Void Function(
    Int32 alertType,
    Int64 id,
    Pointer<Utf8> message,
    Pointer<Uint8> data,
    Int32 dataLen,
    Pointer<Void> userData);
typedef LtAlertCallbackDart = void Function(
    int alertType,
    int id,
    Pointer<Utf8> message,
    Pointer<Uint8> data,
    int dataLen,
    Pointer<Void> userData);

// ─── Session ──────────────────────────────────────────────────────────────────
typedef _CreateSessionN = Pointer<LtSessionOpaque> Function(
    Pointer<Utf8>, Int32, Int32);
typedef LtCreateSession = Pointer<LtSessionOpaque> Function(
    Pointer<Utf8>, int, int);

typedef _DestroySessionN = Void Function(Pointer<LtSessionOpaque>);
typedef LtDestroySession = void Function(Pointer<LtSessionOpaque>);

typedef _PollAlertsN = Void Function(
    Pointer<LtSessionOpaque>,
    Pointer<NativeFunction<LtAlertCallbackNative>>,
    Pointer<Void>);
typedef LtPollAlerts = void Function(
    Pointer<LtSessionOpaque>,
    Pointer<NativeFunction<LtAlertCallbackNative>>,
    Pointer<Void>);

typedef _SetAlertCallbackN = Void Function(
    Pointer<LtSessionOpaque>,
    Pointer<NativeFunction<LtAlertCallbackNative>>,
    Pointer<Void>);
typedef LtSetAlertCallback = void Function(
    Pointer<LtSessionOpaque>,
    Pointer<NativeFunction<LtAlertCallbackNative>>,
    Pointer<Void>);

// ─── Torrent management ──────────────────────────────────────────────────────
typedef _AddMagnetN = Int64 Function(
    Pointer<LtSessionOpaque>, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef LtAddMagnet = int Function(
    Pointer<LtSessionOpaque>, Pointer<Utf8>, Pointer<Utf8>, int);

typedef _AddTorrentFileN = Int64 Function(
    Pointer<LtSessionOpaque>, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef LtAddTorrentFile = int Function(
    Pointer<LtSessionOpaque>, Pointer<Utf8>, Pointer<Utf8>, int);

typedef _AddMagnetResumeN = Int64 Function(
    Pointer<LtSessionOpaque>, Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Uint8>, Int32);
typedef LtAddMagnetResume = int Function(
    Pointer<LtSessionOpaque>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Uint8>, int);

typedef _AddTorrentFileResumeN = Int64 Function(
    Pointer<LtSessionOpaque>, Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Uint8>, Int32);
typedef LtAddTorrentFileResume = int Function(
    Pointer<LtSessionOpaque>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Uint8>, int);

typedef _TakeSavedResumeDataN = Int64 Function(
    Pointer<LtSessionOpaque>, Int64, Pointer<Uint8>, Int32);
typedef LtTakeSavedResumeData = int Function(
    Pointer<LtSessionOpaque>, int, Pointer<Uint8>, int);

typedef _LoadResumeDataN = Int32 Function(
    Pointer<LtSessionOpaque>, Int64, Pointer<Uint8>, Int32);
typedef LtLoadResumeData = int Function(
    Pointer<LtSessionOpaque>, int, Pointer<Uint8>, int);

typedef _RemoveTorrentN = Void Function(
    Pointer<LtSessionOpaque>, Int64, Int32);
typedef LtRemoveTorrent = void Function(
    Pointer<LtSessionOpaque>, int, int);

typedef _PauseTorrentN = Void Function(Pointer<LtSessionOpaque>, Int64);
typedef LtPauseTorrent = void Function(Pointer<LtSessionOpaque>, int);

typedef _ResumeTorrentN = Void Function(Pointer<LtSessionOpaque>, Int64);
typedef LtResumeTorrent = void Function(Pointer<LtSessionOpaque>, int);

typedef _RecheckTorrentN = Void Function(Pointer<LtSessionOpaque>, Int64);
typedef LtRecheckTorrent = void Function(Pointer<LtSessionOpaque>, int);

typedef _ForceReannounceN = Void Function(Pointer<LtSessionOpaque>, Int64);
typedef LtForceReannounce = void Function(Pointer<LtSessionOpaque>, int);

typedef _ForceDhtAnnounceN = Void Function(Pointer<LtSessionOpaque>, Int64);
typedef LtForceDhtAnnounce = void Function(Pointer<LtSessionOpaque>, int);

typedef _SaveResumeDataN = Void Function(Pointer<LtSessionOpaque>, Int64);
typedef LtSaveResumeData = void Function(Pointer<LtSessionOpaque>, int);

// ─── Status ──────────────────────────────────────────────────────────────────
typedef _GetTorrentCountN = Int32 Function(Pointer<LtSessionOpaque>);
typedef LtGetTorrentCount = int Function(Pointer<LtSessionOpaque>);

typedef _GetAllStatusesN = Int32 Function(
    Pointer<LtSessionOpaque>, Pointer<LtTorrentStatus>, Int32);
typedef LtGetAllStatuses = int Function(
    Pointer<LtSessionOpaque>, Pointer<LtTorrentStatus>, int);

typedef _GetStatusN = Int32 Function(
    Pointer<LtSessionOpaque>, Int64, Pointer<LtTorrentStatus>);
typedef LtGetStatus = int Function(
    Pointer<LtSessionOpaque>, int, Pointer<LtTorrentStatus>);

// ─── File enumeration & priorities ──────────────────────────────────────────
typedef _GetFileCountN = Int32 Function(Pointer<LtSessionOpaque>, Int64);
typedef LtGetFileCount = int Function(Pointer<LtSessionOpaque>, int);

typedef _GetFilesN = Int32 Function(
    Pointer<LtSessionOpaque>, Int64, Pointer<LtFileInfo>, Int32);
typedef LtGetFiles = int Function(
    Pointer<LtSessionOpaque>, int, Pointer<LtFileInfo>, int);

typedef _GetFileProgressN = Int32 Function(
    Pointer<LtSessionOpaque>, Int64, Pointer<Int64>, Int32);
typedef LtGetFileProgress = int Function(
    Pointer<LtSessionOpaque>, int, Pointer<Int64>, int);

typedef _GetFilePrioritiesN = Int32 Function(
    Pointer<LtSessionOpaque>, Int64, Pointer<Int32>, Int32);
typedef LtGetFilePriorities = int Function(
    Pointer<LtSessionOpaque>, int, Pointer<Int32>, int);

typedef _SetFilePrioritiesN = Void Function(
    Pointer<LtSessionOpaque>, Int64, Pointer<Int32>, Int32);
typedef LtSetFilePriorities = void Function(
    Pointer<LtSessionOpaque>, int, Pointer<Int32>, int);

// ─── Trackers ────────────────────────────────────────────────────────────────
typedef _GetTrackersN = Int32 Function(
    Pointer<LtSessionOpaque>, Int64, Pointer<LtTrackerInfo>, Int32);
typedef LtGetTrackers = int Function(
    Pointer<LtSessionOpaque>, int, Pointer<LtTrackerInfo>, int);

typedef _AddTrackerN = Void Function(
    Pointer<LtSessionOpaque>, Int64, Pointer<Utf8>, Int32);
typedef LtAddTracker = void Function(
    Pointer<LtSessionOpaque>, int, Pointer<Utf8>, int);

typedef _RemoveTrackerN = Void Function(
    Pointer<LtSessionOpaque>, Int64, Pointer<Utf8>);
typedef LtRemoveTracker = void Function(
    Pointer<LtSessionOpaque>, int, Pointer<Utf8>);

// ─── Flags & Piece Deadline ──────────────────────────────────────────────────
typedef _SetSequentialDownloadN = Void Function(Pointer<LtSessionOpaque>, Int64, Int32);
typedef LtSetSequentialDownload = void Function(Pointer<LtSessionOpaque>, int, int);

typedef _SetSuperSeedingN = Void Function(Pointer<LtSessionOpaque>, Int64, Int32);
typedef LtSetSuperSeeding = void Function(Pointer<LtSessionOpaque>, int, int);

typedef _SetPieceDeadlineN = Void Function(Pointer<LtSessionOpaque>, Int64, Int32, Int32);
typedef LtSetPieceDeadline = void Function(Pointer<LtSessionOpaque>, int, int, int);

// ─── Stream management ──────────────────────────────────────────────────────
typedef _StartStreamN = Int64 Function(
    Pointer<LtSessionOpaque>, Int64, Int32, Int64);
typedef LtStartStream = int Function(
    Pointer<LtSessionOpaque>, int, int, int);

typedef _StopStreamN = Void Function(Pointer<LtSessionOpaque>, Int64);
typedef LtStopStream = void Function(Pointer<LtSessionOpaque>, int);

typedef _GetStreamStatusN = Int32 Function(
    Pointer<LtSessionOpaque>, Int64, Pointer<LtStreamStatus>);
typedef LtGetStreamStatus = int Function(
    Pointer<LtSessionOpaque>, int, Pointer<LtStreamStatus>);

typedef _GetAllStreamStatusesN = Int32 Function(
    Pointer<LtSessionOpaque>, Pointer<LtStreamStatus>, Int32);
typedef LtGetAllStreamStatuses = int Function(
    Pointer<LtSessionOpaque>, Pointer<LtStreamStatus>, int);

// ─── Preload — port of torr/preload.go ────────────────────────────────────────
typedef _PreloadStreamN = Int32 Function(
    Pointer<LtSessionOpaque>, Int64, Int64);
typedef LtPreloadStream = int Function(
    Pointer<LtSessionOpaque>, int, int);

// ─── Cache settings — port of settings/btsets.go ─────────────────────────────
typedef _SetCacheSettingsN = Void Function(
    Pointer<LtSessionOpaque>, Int64, Int64, Int32, Int32);
typedef LtSetCacheSettings = void Function(
    Pointer<LtSessionOpaque>, int, int, int, int);

// ─── lt_bt_config — port of settings/btsets.go BTSets ────────────────────────
final class LtBtConfig extends Struct {
  @Int64()  external int cacheSize;
  @Int32()  external int readerReadAhead;
  @Int32()  external int preloadCache;
  @Int32()  external int connectionsLimit;
  @Int32()  external int torrentDisconnectTimeout;
  @Int32()  external int forceEncrypt;
  @Int32()  external int disableTcp;
  @Int32()  external int disableUtp;
  @Int32()  external int disableUpload;
  @Int32()  external int disableDht;
  @Int32()  external int disableUpnp;
  @Int32()  external int enableIpv6;
  @Int32()  external int downloadRateLimit;
  @Int32()  external int uploadRateLimit;
  @Int32()  external int peersListenPort;
  @Int32()  external int responsiveMode;
}

// ─── Engine config — port of btserver.go configure() ─────────────────────────
typedef _ConfigureSessionN = Void Function(
    Pointer<LtSessionOpaque>, Pointer<LtBtConfig>);
typedef LtConfigureSession = void Function(
    Pointer<LtSessionOpaque>, Pointer<LtBtConfig>);

typedef _GetDefaultConfigN = Void Function(Pointer<LtBtConfig>);
typedef LtGetDefaultConfig = void Function(Pointer<LtBtConfig>);

typedef _GetActiveStreamsN = Int32 Function(Pointer<LtSessionOpaque>);
typedef LtGetActiveStreams = int Function(Pointer<LtSessionOpaque>);

// ─── Settings ────────────────────────────────────────────────────────────────
typedef _SetDownloadLimitN = Void Function(Pointer<LtSessionOpaque>, Int32);
typedef LtSetDownloadLimit = void Function(Pointer<LtSessionOpaque>, int);

typedef _SetUploadLimitN = Void Function(Pointer<LtSessionOpaque>, Int32);
typedef LtSetUploadLimit = void Function(Pointer<LtSessionOpaque>, int);

// ─── Utility ─────────────────────────────────────────────────────────────────
typedef _LastErrorN = Pointer<Utf8> Function();
typedef LtLastError = Pointer<Utf8> Function();

typedef _VersionN = Pointer<Utf8> Function();
typedef LtVersion = Pointer<Utf8> Function();

// ─── Helper: read fixed char array ──────────────────────────────────────────
String readCharArray(Array<Char> arr, int maxLen) {
  final bytes = <int>[];
  for (var i = 0; i < maxLen; i++) {
    final c = arr[i] & 0xFF;
    if (c == 0) break;
    bytes.add(c);
  }
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return String.fromCharCodes(bytes);
  }
}

// ─── Cross-platform library resolution ──────────────────────────────────────
DynamicLibrary _openNativeLib() {
  const libName = 'libtorrent_flutter';
  if (Platform.isWindows) {
    return DynamicLibrary.open('$libName.dll');
  } else if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$libName.so');
  } else if (Platform.isMacOS) {
    return DynamicLibrary.open('lib$libName.dylib');
  } else if (Platform.isIOS) {
    return DynamicLibrary.process();
  }
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

// ─── Binding loader ─────────────────────────────────────────────────────────
class TorrentBridgeBindings {
  final DynamicLibrary _lib;

  late final LtCreateSession      createSession;
  late final LtDestroySession     destroySession;
  late final LtPollAlerts         pollAlerts;
  late final LtSetAlertCallback   setAlertCallback;
  late final LtAddMagnet          addMagnet;
  late final LtAddMagnetResume?   addMagnetResume;
  late final LtAddTorrentFile     addTorrentFile;
  late final LtAddTorrentFileResume? addTorrentFileResume;
  late final LtRemoveTorrent      removeTorrent;
  late final LtPauseTorrent       pauseTorrent;
  late final LtResumeTorrent      resumeTorrent;
  late final LtRecheckTorrent     recheckTorrent;
  late final LtForceReannounce?   forceReannounce;
  late final LtForceDhtAnnounce?  forceDhtAnnounce;
  late final LtSaveResumeData?    saveResumeData;
  late final LtTakeSavedResumeData? takeSavedResumeData;
  late final LtLoadResumeData?    loadResumeData;
  late final LtGetTorrentCount    getTorrentCount;
  late final LtGetAllStatuses     getAllStatuses;
  late final LtGetStatus          getStatus;
  late final LtGetFileCount       getFileCount;
  late final LtGetFiles           getFiles;
  late final LtGetFileProgress?   getFileProgress;
  late final LtGetFilePriorities? getFilePriorities;
  late final LtSetFilePriorities  setFilePriorities;
  late final LtGetTrackers?       getTrackers;
  late final LtAddTracker?        addTracker;
  late final LtRemoveTracker?     removeTracker;
  late final LtSetSequentialDownload? setSequentialDownload;
  late final LtSetSuperSeeding?   setSuperSeeding;
  late final LtSetPieceDeadline?  setPieceDeadline;
  late final LtStartStream        startStream;
  late final LtStopStream         stopStream;
  late final LtGetStreamStatus    getStreamStatus;
  late final LtGetAllStreamStatuses getAllStreamStatuses;
  late final LtSetDownloadLimit   setDownloadLimit;
  late final LtSetUploadLimit     setUploadLimit;
  late final LtPreloadStream      preloadStream;
  late final LtSetCacheSettings   setCacheSettings;
  late final LtConfigureSession   configureSession;
  late final LtGetDefaultConfig   getDefaultConfig;
  late final LtGetActiveStreams   getActiveStreams;
  late final LtLastError          lastError;
  late final LtVersion            version;

  TorrentBridgeBindings(this._lib) {
    createSession       = _lib.lookup<NativeFunction<_CreateSessionN>>('lt_create_session').asFunction<LtCreateSession>();
    destroySession      = _lib.lookup<NativeFunction<_DestroySessionN>>('lt_destroy_session').asFunction<LtDestroySession>();
    pollAlerts          = _lib.lookup<NativeFunction<_PollAlertsN>>('lt_poll_alerts').asFunction<LtPollAlerts>();
    setAlertCallback    = _lib.lookup<NativeFunction<_SetAlertCallbackN>>('lt_set_alert_callback').asFunction<LtSetAlertCallback>();
    addMagnet           = _lib.lookup<NativeFunction<_AddMagnetN>>('lt_add_magnet').asFunction<LtAddMagnet>();
    try {
      addMagnetResume = _lib.lookup<NativeFunction<_AddMagnetResumeN>>(
        'lt_add_magnet_resume',
      ).asFunction<LtAddMagnetResume>();
    } catch (_) {
      addMagnetResume = null;
    }
    addTorrentFile      = _lib.lookup<NativeFunction<_AddTorrentFileN>>('lt_add_torrent_file').asFunction<LtAddTorrentFile>();
    try {
      addTorrentFileResume = _lib.lookup<NativeFunction<_AddTorrentFileResumeN>>(
        'lt_add_torrent_file_resume',
      ).asFunction<LtAddTorrentFileResume>();
    } catch (_) {
      addTorrentFileResume = null;
    }
    removeTorrent       = _lib.lookup<NativeFunction<_RemoveTorrentN>>('lt_remove_torrent').asFunction<LtRemoveTorrent>();
    pauseTorrent        = _lib.lookup<NativeFunction<_PauseTorrentN>>('lt_pause_torrent').asFunction<LtPauseTorrent>();
    resumeTorrent       = _lib.lookup<NativeFunction<_ResumeTorrentN>>('lt_resume_torrent').asFunction<LtResumeTorrent>();
    recheckTorrent      = _lib.lookup<NativeFunction<_RecheckTorrentN>>('lt_recheck_torrent').asFunction<LtRecheckTorrent>();
    try {
      forceReannounce = _lib.lookup<NativeFunction<_ForceReannounceN>>(
        'lt_force_reannounce',
      ).asFunction<LtForceReannounce>();
    } catch (_) {
      forceReannounce = null;
    }
    try {
      forceDhtAnnounce = _lib.lookup<NativeFunction<_ForceDhtAnnounceN>>(
        'lt_force_dht_announce',
      ).asFunction<LtForceDhtAnnounce>();
    } catch (_) {
      forceDhtAnnounce = null;
    }
    try {
      saveResumeData = _lib.lookup<NativeFunction<_SaveResumeDataN>>(
        'lt_save_resume_data',
      ).asFunction<LtSaveResumeData>();
    } catch (_) {
      saveResumeData = null;
    }
    try {
      takeSavedResumeData = _lib.lookup<NativeFunction<_TakeSavedResumeDataN>>(
        'lt_take_saved_resume_data',
      ).asFunction<LtTakeSavedResumeData>();
    } catch (_) {
      takeSavedResumeData = null;
    }
    try {
      loadResumeData = _lib.lookup<NativeFunction<_LoadResumeDataN>>(
        'lt_load_resume_data',
      ).asFunction<LtLoadResumeData>();
    } catch (_) {
      loadResumeData = null;
    }
    getTorrentCount     = _lib.lookup<NativeFunction<_GetTorrentCountN>>('lt_get_torrent_count').asFunction<LtGetTorrentCount>();
    getAllStatuses       = _lib.lookup<NativeFunction<_GetAllStatusesN>>('lt_get_all_statuses').asFunction<LtGetAllStatuses>();
    getStatus           = _lib.lookup<NativeFunction<_GetStatusN>>('lt_get_status').asFunction<LtGetStatus>();
    getFileCount        = _lib.lookup<NativeFunction<_GetFileCountN>>('lt_get_file_count').asFunction<LtGetFileCount>();
    getFiles            = _lib.lookup<NativeFunction<_GetFilesN>>('lt_get_files').asFunction<LtGetFiles>();
    try {
      getFileProgress = _lib.lookup<NativeFunction<_GetFileProgressN>>(
        'lt_get_file_progress',
      ).asFunction<LtGetFileProgress>();
    } catch (_) {
      getFileProgress = null;
    }
    try {
      getFilePriorities = _lib.lookup<NativeFunction<_GetFilePrioritiesN>>(
        'lt_get_file_priorities',
      ).asFunction<LtGetFilePriorities>();
    } catch (_) {
      getFilePriorities = null;
    }
    setFilePriorities   = _lib.lookup<NativeFunction<_SetFilePrioritiesN>>('lt_set_file_priorities').asFunction<LtSetFilePriorities>();
    try {
      getTrackers = _lib.lookup<NativeFunction<_GetTrackersN>>(
        'lt_get_trackers',
      ).asFunction<LtGetTrackers>();
    } catch (_) {
      getTrackers = null;
    }
    try {
      addTracker = _lib.lookup<NativeFunction<_AddTrackerN>>(
        'lt_add_tracker',
      ).asFunction<LtAddTracker>();
    } catch (_) {
      addTracker = null;
    }
    try {
      removeTracker = _lib.lookup<NativeFunction<_RemoveTrackerN>>(
        'lt_remove_tracker',
      ).asFunction<LtRemoveTracker>();
    } catch (_) {
      removeTracker = null;
    }
    try {
      setSequentialDownload = _lib.lookup<NativeFunction<_SetSequentialDownloadN>>(
        'lt_set_sequential_download',
      ).asFunction<LtSetSequentialDownload>();
    } catch (_) {
      setSequentialDownload = null;
    }
    try {
      setSuperSeeding = _lib.lookup<NativeFunction<_SetSuperSeedingN>>(
        'lt_set_super_seeding',
      ).asFunction<LtSetSuperSeeding>();
    } catch (_) {
      setSuperSeeding = null;
    }
    try {
      setPieceDeadline = _lib.lookup<NativeFunction<_SetPieceDeadlineN>>(
        'lt_set_piece_deadline',
      ).asFunction<LtSetPieceDeadline>();
    } catch (_) {
      setPieceDeadline = null;
    }
    startStream         = _lib.lookup<NativeFunction<_StartStreamN>>('lt_start_stream').asFunction<LtStartStream>();
    stopStream          = _lib.lookup<NativeFunction<_StopStreamN>>('lt_stop_stream').asFunction<LtStopStream>();
    getStreamStatus     = _lib.lookup<NativeFunction<_GetStreamStatusN>>('lt_get_stream_status').asFunction<LtGetStreamStatus>();
    getAllStreamStatuses = _lib.lookup<NativeFunction<_GetAllStreamStatusesN>>('lt_get_all_stream_statuses').asFunction<LtGetAllStreamStatuses>();
    setDownloadLimit    = _lib.lookup<NativeFunction<_SetDownloadLimitN>>('lt_set_download_limit').asFunction<LtSetDownloadLimit>();
    setUploadLimit      = _lib.lookup<NativeFunction<_SetUploadLimitN>>('lt_set_upload_limit').asFunction<LtSetUploadLimit>();
    preloadStream       = _lib.lookup<NativeFunction<_PreloadStreamN>>('lt_preload_stream').asFunction<LtPreloadStream>();
    setCacheSettings    = _lib.lookup<NativeFunction<_SetCacheSettingsN>>('lt_set_cache_settings').asFunction<LtSetCacheSettings>();
    configureSession    = _lib.lookup<NativeFunction<_ConfigureSessionN>>('lt_configure_session').asFunction<LtConfigureSession>();
    getDefaultConfig    = _lib.lookup<NativeFunction<_GetDefaultConfigN>>('lt_get_default_config').asFunction<LtGetDefaultConfig>();
    getActiveStreams     = _lib.lookup<NativeFunction<_GetActiveStreamsN>>('lt_get_active_streams').asFunction<LtGetActiveStreams>();
    lastError           = _lib.lookup<NativeFunction<_LastErrorN>>('lt_last_error').asFunction<LtLastError>();
    version             = _lib.lookup<NativeFunction<_VersionN>>('lt_version').asFunction<LtVersion>();
  }

  factory TorrentBridgeBindings.open() => TorrentBridgeBindings(_openNativeLib());
}
