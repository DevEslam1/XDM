import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/mirror_failover.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/core/utils/url_utils.dart';
import '../interfaces/i_download_engine.dart';
import 'dio_client_pool.dart';
import 'yt_counterpart_coordinator.dart';
import 'metadata_probe_service.dart';
import 'http_download_orchestrator.dart';
import 'torrent_download_orchestrator.dart';
import 'engine/engine_models.dart';
import 'engine/engine_utils.dart';
import 'engines/http_download_engine.dart';

export 'engine/engine_models.dart';
export 'engine/engine_utils.dart';
export 'dio_client_pool.dart';
export 'yt_counterpart_coordinator.dart';
export 'metadata_probe_service.dart';
export 'http_download_orchestrator.dart';
export 'torrent_download_orchestrator.dart';

part 'download_isolate_pool.dart';

class IsolateSpawnTimeoutException implements Exception {
  final String message;
  const IsolateSpawnTimeoutException([
    this.message = 'Download engine failed to initialize. Please retry.',
  ]);
  @override
  String toString() => 'IsolateSpawnTimeoutException: $message';
}

class InsufficientStorageException implements Exception {
  final String message;
  const InsufficientStorageException([
    this.message =
        'Not enough storage space to download this file. Please free up space and try again.',
  ]);
  @override
  String toString() => 'InsufficientStorageException: $message';
}

class InvalidPathException implements Exception {
  final String message;
  const InvalidPathException(this.message);
  @override
  String toString() => 'InvalidPathException: $message';
}

class DownloadIntegrityException implements Exception {
  final String message;
  const DownloadIntegrityException(this.message);
  @override
  String toString() => 'DownloadIntegrityException: $message';
}

class UrlExpiredException implements Exception {
  final String message;
  final bool refreshAllMirrors;
  const UrlExpiredException(this.message, {this.refreshAllMirrors = false});
  @override
  String toString() => 'UrlExpiredException: $message';
}

class TorrentEnginePauseException implements Exception {
  final String message;
  final String url;
  const TorrentEnginePauseException(this.message, {required this.url});
  @override
  String toString() => 'TorrentEnginePauseException: $message';
}

class DownloadEngine implements IDownloadEngine {
  static bool appInForeground = true;
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
      return true;
    } catch (_) {
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
    } catch (_) {
      return requestedThreads;
    }
  }

  static bool isLikelyHtmlResponse(dynamic responseOrContentType) {
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
        final audioPath = '$dirOrFilePath.audio';
        final audioFile = File(audioPath);
        if (await audioFile.exists() && mergeConfirmed) {
          try {
            await audioFile.delete();
          } catch (_) {}
        }
        return;
      }
      final directory = Directory(dirOrFilePath);
      if (!await directory.exists()) return;
      final files = await directory.list().toList();
      for (final f in files) {
        if (f is File && f.path.endsWith('.dmxpart.tmp')) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<DownloadIsolatePool> _ensurePool() {
    final existing = _pool;
    if (existing != null) return Future.value(existing);
    return _poolInit ??= () async {
      final pool = DownloadIsolatePool(size: _isolatePoolSize);
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
    if (savePath.contains('..')) {
      throw const InvalidPathException('Path traversal attempt detected in save path');
    }
    final normalized = p.normalize(savePath);
    if (RegExp(r'[\*\?<>\|"\x00]').hasMatch(savePath)) {
      throw const InvalidPathException('Save path contains invalid characters');
    }
    final dir = Directory(normalized);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }
}
