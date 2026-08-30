import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../features/downloads/domain/orchestrators/http_download_orchestrator.dart';
import '../../features/downloads/domain/orchestrators/torrent_download_orchestrator.dart';
import '../di/injection.dart';
import '../interfaces/i_download_engine.dart';
import '../interfaces/i_torrent_service.dart';
import 'dio_client_pool.dart';
import 'engine/engine_exceptions.dart';
import 'engine/engine_models.dart';
import 'engine/http_transfer_job.dart';
import 'engine/torrent_download_handler.dart';
import 'metadata_probe_service.dart';
import 'permission_service.dart';
import 'service_registry.dart';
import 'tick_manager.dart';
import 'yt_counterpart_coordinator.dart';

export 'engine/engine_exceptions.dart';
export 'engine/engine_models.dart';

part 'download_isolate_pool.dart';

class DownloadEngine implements IDownloadEngine {
  static final ValueNotifier<bool> appInForegroundNotifier =
      ValueNotifier<bool>(true);
  static bool get appInForeground => appInForegroundNotifier.value;
  static set appInForeground(bool val) => appInForegroundNotifier.value = val;
  static bool get isInBackground => !appInForeground;
  @Deprecated(
      'Use markForeground() / markBackground() instead — the setter was semantically inverted.')
  static set isInBackground(bool val) => appInForeground = !val;

  /// Explicitly mark the engine as foreground. Prefer over `isInBackground = false`.
  static void markForeground() => appInForeground = true;

  /// Explicitly mark the engine as background. Prefer over `isInBackground = true`.
  static void markBackground() => appInForeground = false;

  static int _activeDownloadsCount = 0;
  static bool get hasActiveDownloads => _activeDownloadsCount > 0;
  static int get activeDownloadsCount => _activeDownloadsCount;
  static void setActiveDownloadsCount(int count) =>
      _activeDownloadsCount = count;

  static DownloadEngine? _latestInstance;

  static void forceKillAllIsolates() {
    _latestInstance?._pool?.forceKillAll();
  }

  static const int _isolatePoolSize = 4;

  late final HttpDownloadOrchestrator _httpOrchestrator;
  late final TorrentDownloadOrchestrator _torrentOrchestrator;
  late final TorrentDownloadHandler _torrentHandler;
  late final MetadataProbeService _metadataService;
  late final YtCounterpartCoordinator _ytCoordinator;
  late final DioClientPool _dioPool;
  late final ITorrentService _torrentService;

  TorrentDownloadOrchestrator get torrentOrchestrator => _torrentOrchestrator;
  TorrentDownloadHandler get torrentHandler => _torrentHandler;

  DownloadIsolatePool? _pool;
  Future<DownloadIsolatePool>? _poolInit;

  DownloadEngine({
    HttpDownloadOrchestrator? httpOrchestrator,
    TorrentDownloadOrchestrator? torrentOrchestrator,
    TorrentDownloadHandler? torrentHandler,
    MetadataProbeService? metadataService,
    YtCounterpartCoordinator? ytCoordinator,
    DioClientPool? dioPool,
    Dio? dio,
    ITorrentService? torrentService,
    bool enableCleanupTimer = true,
  }) {
    // FIX C-4: Create a single shared DioClientPool instead of up to 3 separate
    // instances. All sub-services share the same pool so socket handles, cleanup
    // timers, and connection tracking are centralised.
    final sharedPool =
        dioPool ?? DioClientPool(enableCleanupTimer: enableCleanupTimer);
    final sharedYtCoordinator = ytCoordinator ??
        YtCounterpartCoordinator(enablePeriodicTimer: enableCleanupTimer);
    final sharedMetadata = metadataService ?? MetadataProbeService(sharedPool);
    final resolvedTorrentService = torrentService ??
        (getIt.isRegistered<ITorrentService>()
            ? getIt<ITorrentService>()
            : TorrentServiceImpl());
    final sharedTorrentHandler = torrentHandler ??
        TorrentDownloadHandler(torrentService: resolvedTorrentService);

    _dioPool = sharedPool;
    _torrentService = resolvedTorrentService;
    _ytCoordinator = sharedYtCoordinator;
    _metadataService = sharedMetadata;
    _torrentHandler = sharedTorrentHandler;
    _httpOrchestrator = httpOrchestrator ??
        HttpDownloadOrchestrator(
          sharedMetadata,
          sharedYtCoordinator,
          SettingsProvider.instance,
        );
    _torrentOrchestrator = torrentOrchestrator ??
        TorrentDownloadOrchestrator(
            sharedPool, sharedTorrentHandler, resolvedTorrentService);
    _latestInstance = this;
  }

  String buildLocalFilePath(String dir, String fileName) =>
      p.join(dir, fileName);

  @override
  String buildTempFilePath(String dir, String fileName) =>
      p.join(dir, '$fileName.dmxpart');

  static final Map<String, _DiskSpaceCacheEntry> _diskCheckCache = {};

  @override
  Future<bool> hasEnoughDiskSpace(String saveDir, int requiredBytes) async {
    final normDir = p.normalize(saveDir).toLowerCase();
    final cached = _diskCheckCache[normDir];
    final now = DateTime.now();

    if (cached != null &&
        now.difference(cached.timestamp) < const Duration(seconds: 30)) {
      if (cached.hasSpace && requiredBytes <= cached.checkedBytes) {
        return true;
      }
      if (!cached.hasSpace && requiredBytes >= cached.checkedBytes) {
        return false;
      }
    }

    final result = await hasEnoughDiskSpaceOrNull(saveDir, requiredBytes);
    final finalResult = result ?? false;
    _diskCheckCache[normDir] = _DiskSpaceCacheEntry(
      hasSpace: finalResult,
      checkedBytes: requiredBytes,
      timestamp: now,
    );
    return finalResult;
  }

  /// Like [hasEnoughDiskSpace] but returns `null` when the free-space check
  /// itself fails (unknown), so callers can distinguish "no space" from
  /// "could not determine". The non-nullable variant is fail-safe: it
  /// conservatively reports `false` when the check cannot complete.
  Future<bool?> hasEnoughDiskSpaceOrNull(
      String saveDir, int requiredBytes) async {
    try {
      if (requiredBytes <= 0) return true;
      final dir = Directory(saveDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      if (Platform.isIOS) {
        // iOS/App Store: Process.run is unavailable. Use a stat-based heuristic:
        // Write a 1-byte probe file and check if it succeeds; for larger checks
        // rely on NSFileSystemFreeSize surfaced via path_provider-like APIs.
        // Returning `true` and letting the OS error is safer than spawning a process.
        try {
          final probe = File(p.join(saveDir, '.dmx_probe'));
          await probe.writeAsBytes([0]);
          await probe.delete();
        } catch (_) {
          return false; // write failed → full or inaccessible
        }
        return true;
      } else if (Platform.isAndroid || Platform.isLinux || Platform.isMacOS) {
        // df reports 1K-blocks; column 4 (0-indexed) is available blocks.
        final stat = await Process.run('df', [saveDir]);
        final lines = stat.stdout.toString().split('\n');
        if (lines.length > 1) {
          final parts = lines[1].trim().split(RegExp(r'\s+'));
          if (parts.length >= 4) {
            final availableKb = int.tryParse(parts[3]) ?? 0;
            return (availableKb * 1024) > requiredBytes;
          }
        }
      } else if (Platform.isWindows) {
        // FIX P1-6: Escape single quotes to prevent PowerShell injection.
        // Path "C:\a'; rm ..." previously broke out of single quotes.
        final escaped = saveDir.replaceAll("'", "''");
        final result = await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "(Get-PSDrive -Name (Get-Item -LiteralPath '$escaped').PSDrive.Name).Free"
        ]);
        final freeBytes = int.tryParse(result.stdout.toString().trim()) ?? 0;
        return freeBytes > requiredBytes;
      }
      return true; // fallback: assume enough space
    } catch (e) {
      debugPrint('[DiskCheck] Failed to check disk space: $e');
      return null;
    }
  }

  Future<int> estimateOptimalThreads({
    required String url,
    required int requestedThreads,
    required int fileSize,
    Dio? dio,
    CancelToken? cancelToken,
  }) async {
    if (requestedThreads <= 1 || fileSize < 512 * 1024) {
      return 1;
    }
    final client = dio ?? Dio();
    try {
      final response = await client.head(
        url,
        cancelToken: cancelToken,
        options: Options(
          headers: {'range': 'bytes=0-0'},
          followRedirects: true,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final acceptRanges =
          response.headers.value('accept-ranges')?.toLowerCase();
      final connection = response.headers.value('connection')?.toLowerCase();
      if (acceptRanges == 'none' || connection == 'close') {
        return 1;
      }
      return requestedThreads;
    } catch (e, st) {
      LoggingService.logger('DownloadEngine')
          .warning('Operation failed with fallback', e, st);
      return requestedThreads;
    }
  }

  bool isLikelyHtmlResponse(dynamic responseOrContentType) {
    if (responseOrContentType == null) return false;
    String contentType = '';
    if (responseOrContentType is Response) {
      contentType =
          responseOrContentType.headers.value('content-type')?.toLowerCase() ??
              '';
    } else if (responseOrContentType is String) {
      contentType = responseOrContentType.toLowerCase();
    }
    return contentType.contains('text/html') ||
        contentType.contains('application/xhtml+xml');
  }

  bool isLikelyHtml(dynamic responseOrContentType) =>
      isLikelyHtmlResponse(responseOrContentType);

  static Future<void> cleanupOrphanFiles(String dirOrFilePath,
      {bool mergeConfirmed = false}) async {
    try {
      final file = File(dirOrFilePath);
      if (await file.exists() || dirOrFilePath.endsWith('.dmxpart')) {
        final basePath = dirOrFilePath.endsWith('.dmxpart')
            ? dirOrFilePath.substring(0, dirOrFilePath.length - 8)
            : dirOrFilePath;
        final dir = file.parent;
        final baseName = p.basename(basePath);

        if (await dir.exists()) {
          final entries = await dir.list().toList();
          for (final entity in entries) {
            if (entity is File) {
              final name = p.basename(entity.path);
              if (name == p.basename(dirOrFilePath) ||
                  name == '$baseName.dmxpart' ||
                  name == '$baseName.dmxstate' ||
                  name == '$baseName.journal' ||
                  name == '$baseName.audio' ||
                  name.startsWith('$baseName.part') ||
                  name.startsWith('$baseName.dmxpart')) {
                try {
                  await entity.delete();
                } catch (e, st) {
                  LoggingService.logger('DownloadEngine')
                      .warning('Operation failed', e, st);
                }
              }
            }
          }
        }
        return;
      }
      final directory = Directory(dirOrFilePath);
      if (!await directory.exists()) return;
      final files = await directory.list().toList();
      for (final f in files) {
        if (f is File &&
            (f.path.endsWith('.dmxpart.tmp') || f.path.endsWith('.tmp'))) {
          try {
            await f.delete();
          } catch (e, st) {
            LoggingService.logger('DownloadEngine')
                .warning('Operation failed', e, st);
          }
        }
      }
    } catch (e, st) {
      LoggingService.logger('DownloadEngine')
          .warning('Operation failed', e, st);
    }
  }

  /// Sweeps orphaned temporary and partial files (*.part, *.tmp, *.dmxpart.tmp)
  /// older than [maxAge] (default: 24 hours) from the target download/temp directory.
  static Future<int> sweepStaleTempFiles(
    String directoryPath, {
    Duration maxAge = const Duration(hours: 24),
  }) async {
    int deletedCount = 0;
    try {
      final dir = Directory(directoryPath);
      if (!await dir.exists()) return 0;
      final cutoff = DateTime.now().subtract(maxAge);
      final entries = await dir.list(recursive: false).toList();
      for (final entity in entries) {
        if (entity is File) {
          final path = entity.path.toLowerCase();
          final isTempOrPart = path.endsWith('.tmp') ||
              path.endsWith('.part') ||
              path.endsWith('.dmxpart.tmp') ||
              path.endsWith('.audio.tmp') ||
              path.endsWith('.part.tmp');
          if (isTempOrPart) {
            try {
              final stat = await entity.stat();
              if (stat.modified.isBefore(cutoff)) {
                await entity.delete();
                deletedCount++;
                LoggingService.logger('DownloadEngine').info(
                    'Deleted stale temp file: ${entity.path} (modified ${stat.modified})');
              }
            } catch (e, st) {
              LoggingService.logger('DownloadEngine').fine(
                  'Failed to check/delete temp file: ${entity.path}', e, st);
            }
          }
        }
      }
    } catch (e, st) {
      LoggingService.logger('DownloadEngine')
          .warning('Stale temp sweep failed for $directoryPath', e, st);
    }
    return deletedCount;
  }

  Future<DownloadIsolatePool> _ensurePool() {
    final existing = _pool;
    if (existing != null) return Future.value(existing);
    return _poolInit ??= () async {
      try {
        final pool = DownloadIsolatePool(
          size: _isolatePoolSize,
          powerAware: true,
        );
        ServiceRegistry.registerMemoryPressureListener(pool);
        await pool.init();
        _pool = pool;
        return pool;
      } catch (e) {
        // FIX(N5): Reset _poolInit on failure so a transient error doesn't poison future attempts
        _poolInit = null;
        rethrow;
      }
    }();
  }

  @override
  Future<DownloadMetadata> resolveMetadata({
    required String url,
    String? requestedFileName,
    String? customUserAgent,
    String? referer,
    String? cookies,
    String? oauthToken,
    CancelToken? cancelToken,
  }) =>
      _metadataService.resolveMetadata(
        url: url,
        requestedFileName: requestedFileName,
        customUserAgent: customUserAgent,
        referer: referer,
        cookies: cookies,
        oauthToken: oauthToken,
        cancelToken: cancelToken,
      );

  @override
  Future<void> downloadRequest(DownloadRequest request) {
    return download(
      taskId: request.taskId,
      url: request.url,
      tempFilePath: request.tempFilePath,
      localFilePath: request.localFilePath,
      knownFileSize: request.knownFileSize,
      supportsResume: request.supportsResume,
      cancelToken: request.cancelToken,
      onProgress: request.onProgress,
      speedLimitBytesPerSecond: request.speedLimitBytesPerSecond,
      activeDownloadCount: request.activeDownloadCount,
      threadCount: request.threadCount,
      customUserAgent: request.customUserAgent,
      referer: request.referer,
      cookies: request.cookies,
      oauthToken: request.oauthToken,
      getTorrentFiles: request.getTorrentFiles,
      torrentId: request.torrentId,
      isNameAutoGenerated: request.isNameAutoGenerated,
      mirrorUrls: request.mirrorUrls,
      adaptiveThreads: request.adaptiveThreads,
      speedLimitKbps: request.speedLimitKbps,
      ytStreamKind: request.ytStreamKind,
      ytCounterpartSize: request.ytCounterpartSize,
      ytCounterpartDownloadedBytes: request.ytCounterpartDownloadedBytes,
      isRetry: request.isRetry,
      metadataTimeoutSeconds: request.metadataTimeoutSeconds,
    );
  }

  @override
  Future<void> download({
    required String taskId,
    required String url,
    required String tempFilePath,
    required String localFilePath,
    required int knownFileSize,
    required bool supportsResume,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    required int Function() speedLimitBytesPerSecond,
    required int Function() activeDownloadCount,
    int threadCount = 0,
    String? customUserAgent,
    String? referer,
    String? cookies,
    String? oauthToken,
    String? authUsername,
    String? authPassword,
    Map<String, String>? customHeaders,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int? torrentId,
    bool isNameAutoGenerated = false,
    List<String>? mirrorUrls,
    bool adaptiveThreads = false,
    int speedLimitKbps = 0,
    YtStreamKind? ytStreamKind,
    int? ytCounterpartSize,
    int? ytCounterpartDownloadedBytes,
    bool isRetry = false,
    int? metadataTimeoutSeconds,
  }) async {
    final permService = PermissionService();
    if (!await permService.isStoragePermissionValid()) {
      onProgress(DownloadProgress(
        downloadedBytes: 0,
        fileSize: knownFileSize,
        speed: 0,
        eta: null,
        cycleState: CycleState.paused,
        pauseReason: PauseReason.permissionRevoked,
        statusMessage: 'Storage permission revoked',
      ));
      return;
    }

    final isTorrent = isTorrentUrl(url, fileName: p.basename(localFilePath));
    if (isTorrent) {
      return _torrentHandler.handleTorrentDownload(
        taskId: taskId,
        url: url,
        currentLocalFilePath: localFilePath,
        knownFileSize: knownFileSize,
        cancelToken: cancelToken,
        onProgress: onProgress,
        getTorrentFiles: getTorrentFiles,
        torrentId: torrentId,
        clientBuilder: (url) => _dioPool.acquireClient(url: url),
        clientReleaser: (client) => _dioPool.releaseClient(client),
        isRetry: isRetry,
        // B1: forward the user-configured metadata timeout — it was received
        // here but silently dropped, so the setting never reached the magnet
        // add call.
        metadataTimeoutSeconds: metadataTimeoutSeconds,
      );
    }

    final pool = await _ensurePool();
    return _httpOrchestrator.download(
      taskId: taskId,
      url: url,
      tempFilePath: tempFilePath,
      localFilePath: localFilePath,
      knownFileSize: knownFileSize,
      supportsResume: supportsResume,
      cancelToken: cancelToken,
      onProgress: onProgress,
      pool: pool,
      threadCount: threadCount,
      customUserAgent: customUserAgent,
      referer: referer,
      cookies: cookies,
      oauthToken: oauthToken,
      authUsername: authUsername,
      authPassword: authPassword,
      customHeaders: customHeaders,
      isNameAutoGenerated: isNameAutoGenerated,
      mirrorUrls: mirrorUrls,
      adaptiveThreads: adaptiveThreads,
      speedLimitKbps: speedLimitKbps,
      ytStreamKind: ytStreamKind,
      ytCounterpartSize: ytCounterpartSize,
      ytCounterpartDownloadedBytes: ytCounterpartDownloadedBytes,
      isRetry: isRetry,
    );
  }

  @override
  void updateSpeedLimit(int bytesPerSecond, int activeCount) {
    // FIX(C4): Use injected _torrentService for speed limits
    _torrentService.setDownloadLimit(bytesPerSecond);
    _pool?.updateSpeedLimit(bytesPerSecond, activeCount);
  }

  void registerYtCounterpart(String taskId, String counterpartTaskId) {
    _ytCoordinator.registerCounterpart(taskId, counterpartTaskId);
  }

  void dispose() {
    if (_latestInstance == this) {
      _latestInstance = null;
    }
    if (_pool != null) {
      ServiceRegistry.unregisterMemoryPressureListener(_pool!);
    }
    _pool?.dispose();
    _dioPool.dispose();
    _ytCoordinator.dispose();
  }

  @override
  Future<void> close() async {
    dispose();
  }

  @override
  void forceCancelJob(String taskId) {
    _pool?.forceCancelJob(taskId);
  }

  static Future<void> validateSavePath(
    String savePath, {
    int requiredSizeBytes = 0,
    List<String>? allowedStorageRoots,
  }) async {
    final rawSegments = p.split(savePath);
    final normSegments = p.split(p.normalize(savePath));
    if (rawSegments.any((s) => s == '..' || s == '.') ||
        normSegments.any((s) => s == '..')) {
      throw const InvalidPathException('Path traversal attempt detected');
    }
    if (RegExp(r'[\*\?<>\|"\x00]').hasMatch(savePath)) {
      throw const InvalidPathException('Save path contains invalid characters');
    }
    if (allowedStorageRoots != null && allowedStorageRoots.isNotEmpty) {
      final normSave = p.normalize(savePath);
      final isAllowed = allowedStorageRoots.any((root) {
        final normRoot = p.normalize(root);
        return p.isWithin(normRoot, normSave) || p.equals(normRoot, normSave);
      });
      if (!isAllowed) {
        throw const InvalidPathException(
            'Save path is outside allowed storage roots');
      }
    }
    try {
      final normalized = p.normalize(savePath);
      final dir = Directory(normalized);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (e) {
      if (e is InvalidPathException) rethrow;
    }
  }
}

// FIX(N4): Disk space cache entry tracking path-specific checks and tested capacities
class _DiskSpaceCacheEntry {
  final bool hasSpace;
  final int checkedBytes;
  final DateTime timestamp;

  _DiskSpaceCacheEntry({
    required this.hasSpace,
    required this.checkedBytes,
    required this.timestamp,
  });
}
