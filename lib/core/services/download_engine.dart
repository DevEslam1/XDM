import 'package:dmx/core/services/logging_service.dart';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/core/utils/url_utils.dart';
import '../interfaces/i_download_engine.dart';
import 'dio_client_pool.dart';
import 'service_registry.dart';
import 'yt_counterpart_coordinator.dart';
import 'metadata_probe_service.dart';
import 'http_download_orchestrator.dart';
import 'torrent_download_orchestrator.dart';
import 'engine/engine_models.dart';
import 'engine/engine_exceptions.dart';
import 'engine/http_transfer_job.dart';

export 'engine/engine_exceptions.dart';
export 'engine/engine_models.dart';
export 'engine/engine_utils.dart';
export 'engine/http_transfer_job.dart';
export 'dio_client_pool.dart';
export 'yt_counterpart_coordinator.dart';
export 'metadata_probe_service.dart';
export 'http_download_orchestrator.dart';
export 'torrent_download_orchestrator.dart';

part 'download_isolate_pool.dart';

class DownloadEngine implements IDownloadEngine {
  static final ValueNotifier<bool> appInForegroundNotifier =
      ValueNotifier<bool>(true);
  static bool get appInForeground => appInForegroundNotifier.value;
  static set appInForeground(bool val) => appInForegroundNotifier.value = val;
  static bool get isInBackground => !appInForeground;
  static set isInBackground(bool val) => appInForeground = !val;
  static const int _isolatePoolSize = 4;

  final HttpDownloadOrchestrator _httpOrchestrator;
  final TorrentDownloadOrchestrator _torrentOrchestrator;
  final MetadataProbeService _metadataService;
  final YtCounterpartCoordinator _ytCoordinator;
  final DioClientPool _dioPool;

  DownloadIsolatePool? _pool;
  Future<DownloadIsolatePool>? _poolInit;

  DownloadEngine({
    HttpDownloadOrchestrator? httpOrchestrator,
    TorrentDownloadOrchestrator? torrentOrchestrator,
    MetadataProbeService? metadataService,
    YtCounterpartCoordinator? ytCoordinator,
    DioClientPool? dioPool,
    Dio? dio,
    bool enableCleanupTimer = true,
  })  : _dioPool = dioPool ?? DioClientPool(),
        _ytCoordinator = ytCoordinator ?? YtCounterpartCoordinator(),
        _metadataService = metadataService ??
            MetadataProbeService(dioPool ?? DioClientPool()),
        _httpOrchestrator = httpOrchestrator ??
            HttpDownloadOrchestrator(
              metadataService ??
                  MetadataProbeService(dioPool ?? DioClientPool()),
              ytCoordinator ?? YtCounterpartCoordinator(),
              SettingsProvider.instance,
            ),
        _torrentOrchestrator = torrentOrchestrator ??
            TorrentDownloadOrchestrator(dioPool ?? DioClientPool());

  String buildLocalFilePath(String dir, String fileName) =>
      p.join(dir, fileName);

  String buildTempFilePath(String dir, String fileName) =>
      p.join(dir, '$fileName.dmxpart');

  Future<bool> hasEnoughDiskSpace(String saveDir, int requiredBytes) async {
    try {
      if (requiredBytes <= 0) return true;
      final dir = Directory(saveDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      if (Platform.isAndroid) {
        final stat = await Process.run('df', [saveDir]);
        final lines = stat.stdout.toString().split('\n');
        if (lines.length > 1) {
          final parts = lines[1].trim().split(RegExp(r'\s+'));
          if (parts.length >= 4) {
            final availableKb = int.tryParse(parts[3]) ?? 0;
            final availableBytes = availableKb * 1024;
            return availableBytes > requiredBytes;
          }
        }
      } else if (Platform.isIOS || Platform.isMacOS || Platform.isLinux) {
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
        // Use PowerShell on Windows
        final result = await Process.run('powershell', [
          '-Command',
          '(Get-PSDrive -Name (Get-Item \'$saveDir\').PSDrive.Name).Free'
        ]);
        final freeBytes = int.tryParse(result.stdout.toString().trim()) ?? 0;
        return freeBytes > requiredBytes;
      }
      return true; // fallback: assume enough space
    } catch (e) {
      debugPrint('[DiskCheck] Failed to check disk space: $e');
      return true;
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
      final acceptRanges = response.headers.value('accept-ranges')?.toLowerCase();
      final connection = response.headers.value('connection')?.toLowerCase();
      if (acceptRanges == 'none' || connection == 'close') {
        return 1;
      }
      return requestedThreads;
    } catch (e, st) {
      LoggingService.logger('DownloadEngine').warning('Operation failed with fallback', e, st);
      return requestedThreads;
    }
  }

  bool isLikelyHtmlResponse(dynamic responseOrContentType) {
    if (responseOrContentType == null) return false;
    String contentType = '';
    if (responseOrContentType is Response) {
      contentType =
          responseOrContentType.headers.value('content-type')?.toLowerCase() ?? '';
    } else if (responseOrContentType is String) {
      contentType = responseOrContentType.toLowerCase();
    }
    return contentType.contains('text/html') ||
        contentType.contains('application/xhtml+xml');
  }

  bool isLikelyHtml(dynamic responseOrContentType) =>
      isLikelyHtmlResponse(responseOrContentType);

  static Future<void> cleanupOrphanFiles(String dirOrFilePath, {bool mergeConfirmed = false}) async {
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
      LoggingService.logger('DownloadEngine').warning('Operation failed', e, st);
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
        if (f is File && (f.path.endsWith('.dmxpart.tmp') || f.path.endsWith('.tmp'))) {
          try {
            await f.delete();
          } catch (e, st) {
      LoggingService.logger('DownloadEngine').warning('Operation failed', e, st);
    }
        }
      }
    } catch (e, st) {
      LoggingService.logger('DownloadEngine').warning('Operation failed', e, st);
    }
  }

  Future<DownloadIsolatePool> _ensurePool() {
    final existing = _pool;
    if (existing != null) return Future.value(existing);
    return _poolInit ??= () async {
      final pool = DownloadIsolatePool(
        size: _isolatePoolSize,
        powerAware: true,
      );
      ServiceRegistry.registerMemoryPressureListener(pool);
      await pool.init();
      _pool = pool;
      return pool;
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
    final isTorrent = isTorrentUrl(url, fileName: p.basename(localFilePath));
    if (isTorrent) {
      return _torrentOrchestrator.download(
        url: url,
        currentLocalFilePath: localFilePath,
        knownFileSize: knownFileSize,
        cancelToken: cancelToken,
        onProgress: onProgress,
        getTorrentFiles: getTorrentFiles,
        torrentId: torrentId,
        isRetry: isRetry,
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

  void updateSpeedLimit(int bytesPerSecond, int activeCount) {
    TorrentService.setDownloadLimit(bytesPerSecond);
    _pool?.updateSpeedLimit(bytesPerSecond, activeCount);
  }

  void registerYtCounterpart(String taskId, String counterpartTaskId) {
    _ytCoordinator.registerCounterpart(taskId, counterpartTaskId);
  }

  void dispose() {
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
        throw const InvalidPathException('Save path is outside allowed storage roots');
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
