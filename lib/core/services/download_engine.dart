import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/mirror_failover.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/retry_interceptor.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'engines/http_download_engine.dart';
import '../utils/bencode_decoder.dart';
import '../utils/file_utils.dart';
import '../utils/url_utils.dart';

part 'download_isolate_pool.dart';

// ═══════════════════════════════════════════════════════════════════════════
// PUBLIC MODELS (API-compatible with orchestrator/provider)
// ═══════════════════════════════════════════════════════════════════════════

class DownloadMetadata {
  final String fileName;
  final String category;
  final int fileSize;
  final bool supportsResume;
  final List<Map<String, dynamic>>? torrentFiles;
  final int? torrentId;

  const DownloadMetadata({
    required this.fileName,
    required this.category,
    required this.fileSize,
    required this.supportsResume,
    this.torrentFiles,
    this.torrentId,
  });
}

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

class DownloadIntegrityException implements Exception {
  final String message;
  const DownloadIntegrityException(this.message);
  @override
  String toString() => 'DownloadIntegrityException: $message';
}

/// ffmpeg failure taxonomy. Exposed so merge call-sites can map failures to
/// user-facing messages WITHOUT string-sniffing; FFmpegMuxService can adopt
/// this without any engine change.
enum MergeFailureKind {
  missingBinary,
  formatMismatch,
  diskFull,
  processCrash,
  incompleteInput,
  unknown,
}

MergeFailureKind classifyMergeFailure(Object error) {
  final msg = error.toString().toLowerCase();
  if (msg.contains('no such file') ||
      msg.contains('ffmpeg_kit') && msg.contains('not initialized') ||
      msg.contains('binary') && msg.contains('missing')) {
    return MergeFailureKind.missingBinary;
  }
  if (msg.contains('no space left') ||
      msg.contains('enospc') ||
      msg.contains('disk full')) {
    return MergeFailureKind.diskFull;
  }
  if (msg.contains('invalid data') ||
      msg.contains('does not contain any stream') ||
      msg.contains('could not open') ||
      msg.contains('invalid argument')) {
    return MergeFailureKind.formatMismatch;
  }
  if (msg.contains('incomplete') || msg.contains('truncated')) {
    return MergeFailureKind.incompleteInput;
  }
  if (msg.contains('crash') ||
      msg.contains('signal') ||
      msg.contains('exit code')) {
    return MergeFailureKind.processCrash;
  }
  return MergeFailureKind.unknown;
}

class DownloadProgress {
  final int downloadedBytes;
  final int fileSize;
  final double speed;
  final int? eta;
  final List<double>? chunks;
  final String? fileName;
  final List<Map<String, dynamic>>? torrentFiles;
  final bool? supportsResume;
  final String? statusMessage;

  DownloadProgress({
    required this.downloadedBytes,
    required this.fileSize,
    required this.speed,
    required this.eta,
    this.chunks,
    this.fileName,
    this.torrentFiles,
    this.supportsResume,
    this.statusMessage,
  });
}

typedef ValueChangedProgress = void Function(DownloadProgress progress);

// ═══════════════════════════════════════════════════════════════════════════
// ENGINE
// ═══════════════════════════════════════════════════════════════════════════

class DownloadEngine {
  static const int _progressReportIntervalMs = 500;
  static const int _isolatePoolSize = 4;
  static const int _lowSpaceThresholdBytes = 500 * 1024 * 1024;

  int get effectiveProgressReportIntervalMs =>
      PowerMonitor.throttleFactor < 1.0 ? 1000 : _progressReportIntervalMs;

  final List<CancelToken> _activeCancelTokens = [];
  DownloadIsolatePool? _pool;
  Future<DownloadIsolatePool>? _poolInit;
  final _httpEngine = HttpDownloadEngine();
  final Set<int> _activeTorrentIds = <int>{};
  final Dio _sharedDio;
  final Set<Dio> _activeDioClients = {};
  final Set<Dio> _reservedDioClients = {};
  final Map<Dio, DateTime> _dioClientCreationTimes = {};
  final Map<Dio, Set<String>> _activeDownloadsPerClient = {};
  Timer? _cleanupTimer;
  bool _closed = false;

  DownloadEngine({
    Dio? dio,
    bool enableCleanupTimer = true,
  }) : _sharedDio = dio ?? Dio() {
    if (enableCleanupTimer) {
      _cleanupTimer = Timer.periodic(const Duration(seconds: 120), (_) {
        if (_closed) return;
        final now = DateTime.now();
        _activeDioClients.removeWhere((client) {
          final active = _activeDownloadsPerClient[client];
          final hasActive = active != null && active.isNotEmpty;
          final age = _dioClientCreationTimes[client] != null
              ? now.difference(_dioClientCreationTimes[client]!)
              : Duration.zero;
          final reserved = _reservedDioClients.contains(client);
          if (hasActive) return false;
          final stale = reserved
              ? age > const Duration(minutes: 10)
              : age > const Duration(minutes: 5);
          if (stale) {
            try {
              client.close(force: true);
            } catch (_) {}
            _reservedDioClients.remove(client);
            _dioClientCreationTimes.remove(client);
            _activeDownloadsPerClient.remove(client);
            return true;
          }
          return false;
        });
      });
    }
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

  @visibleForTesting
  bool isLikelyHtmlResponse(String? contentType) {
    final normalized = (contentType ?? '').toLowerCase();
    return normalized.contains('text/html') ||
        normalized.contains('application/xhtml');
  }

  // ── Dio client construction (main isolate; probes/metadata) ─────────────

  Dio _buildIsolatedClient({
    String? url,
    String? customUserAgent,
    String? referer,
    bool enableProxy = false,
    String? proxyAddress,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool bypassSSL = false,
    String? cookies,
    String? oauthToken,
  }) {
    final client = buildTransferDio(
      url: url,
      customUserAgent: customUserAgent,
      referer: referer,
      enableProxy: enableProxy,
      proxyAddress: proxyAddress,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
      bypassSSL: bypassSSL,
      cookies: cookies,
      oauthToken: oauthToken,
    );
    _activeDioClients.add(client);
    _reservedDioClients.add(client);
    _dioClientCreationTimes[client] = DateTime.now();
    _activeDownloadsPerClient[client] = {};
    return client;
  }

  void _releaseClient(Dio client) {
    _reservedDioClients.remove(client);
    _activeDioClients.remove(client);
    _dioClientCreationTimes.remove(client);
    _activeDownloadsPerClient.remove(client);
    client.close(force: true);
  }

  // ── Metadata resolution (unchanged public behavior) ─────────────────────

  Future<DownloadMetadata> resolveMetadata({
    required String url,
    String? requestedFileName,
    String? customUserAgent,
    String? referer,
    bool enableProxy = false,
    String? proxyAddress,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool bypassSSL = false,
    String? cookies,
    String? oauthToken,
    CancelToken? cancelToken,
  }) async {
    final isTorrent = isTorrentUrl(url, fileName: requestedFileName);
    if (isTorrent) {
      return _resolveTorrentMetadata(
        url: url,
        requestedFileName: requestedFileName,
        cancelToken: cancelToken,
      );
    }

    final punyUrl = convertIdnToPunycode(url);
    var fileName = requestedFileName?.trim().isNotEmpty == true
        ? safeFileName(requestedFileName!.trim())
        : fileNameFromUrl(punyUrl);
    var fileSize = 0;
    final uri = Uri.tryParse(punyUrl);
    final host = uri?.host.toLowerCase() ?? '';
    final isYoutube = host.contains('youtube.com') ||
        host == 'youtu.be' ||
        host.endsWith('.googlevideo.com');
    var supportsResume = isYoutube;

    final isolatedDio = _buildIsolatedClient(
      url: punyUrl,
      customUserAgent: customUserAgent,
      referer: referer,
      enableProxy: enableProxy,
      proxyAddress: proxyAddress,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
      bypassSSL: bypassSSL,
      cookies: cookies,
      oauthToken: oauthToken,
    );
    try {
      final response = await isolatedDio.head<dynamic>(
        punyUrl,
        cancelToken: cancelToken,
        options: Options(followRedirects: true, validateStatus: (_) => true),
      );
      final headerName = fileNameFromContentDisposition(response.headers);
      if (requestedFileName?.trim().isNotEmpty != true && headerName != null) {
        fileName = headerName;
      }
      fileSize = int.tryParse(
              response.headers.value(Headers.contentLengthHeader) ?? '') ??
          0;
      final acceptRanges =
          response.headers.value('accept-ranges')?.toLowerCase();
      supportsResume = acceptRanges != null
          ? acceptRanges == 'bytes'
          : (isYoutube || response.statusCode == 206);

      if (fileSize == 0 ||
          response.statusCode == 403 ||
          response.statusCode == 405 ||
          response.statusCode == 400) {
        try {
          final getResponse = await isolatedDio.get<ResponseBody>(
            punyUrl,
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.stream,
              followRedirects: true,
              headers: {'Range': 'bytes=0-0'},
              validateStatus: (_) => true,
            ),
          );
          if (getResponse.statusCode == 200 || getResponse.statusCode == 206) {
            final getHeaderName =
                fileNameFromContentDisposition(getResponse.headers);
            if (requestedFileName?.trim().isNotEmpty != true &&
                getHeaderName != null) {
              fileName = getHeaderName;
            }
            final contentRange = getResponse.headers.value('content-range');
            if (contentRange != null) {
              final totalMatch = RegExp(r'/(\d+)').firstMatch(contentRange);
              fileSize = int.tryParse(totalMatch?.group(1) ?? '') ?? fileSize;
            }
            if (fileSize == 0) {
              fileSize = int.tryParse(
                      getResponse.headers.value(Headers.contentLengthHeader) ??
                          '') ??
                  0;
            }
            supportsResume = isYoutube ||
                getResponse.statusCode == 206 ||
                getResponse.headers.value('accept-ranges') == 'bytes';
            await getResponse.data?.stream.listen((_) {}).cancel();
          }
        } catch (e) {
          debugPrint('[DownloadEngine] ranged GET probe failed: $e');
        }
      }
    } catch (e) {
      debugPrint('HEAD request failed for ${_redactUrl(punyUrl)}: $e');
    } finally {
      _releaseClient(isolatedDio);
    }
    return DownloadMetadata(
      fileName: fileName,
      category: categoryFromFileName(fileName),
      fileSize: fileSize,
      supportsResume: supportsResume,
    );
  }

  Future<DownloadMetadata> _resolveTorrentMetadata({
    required String url,
    String? requestedFileName,
    CancelToken? cancelToken,
  }) async {
    if (url.startsWith('magnet:')) {
      final magnetParams = parseMagnetUrl(url);
      final resolvedName = requestedFileName?.trim().isNotEmpty == true
          ? safeFileName(requestedFileName!.trim())
          : ((magnetParams['name'] as String?)?.trim().isNotEmpty == true
              ? safeFileName((magnetParams['name'] as String).trim())
              : 'torrent_download.zip');
      final tempDir = (await getTemporaryDirectory()).path;
      final torrentId = TorrentService.addMagnet(url, tempDir);
      TorrentService.resumeTorrent(torrentId);
      TorrentResumeStore.registerSource(torrentId, url);

      final completer = Completer<DownloadMetadata>();
      StreamSubscription? sub;
      Timer? metadataTimer;

      void handleCancel() {
        sub?.cancel();
        metadataTimer?.cancel();
        try {
          TorrentService.pauseTorrent(torrentId);
          TorrentService.removeTorrent(torrentId, deleteFiles: false);
        } catch (_) {}
        if (!completer.isCompleted) {
          completer.completeError(DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.cancel,
            message: 'Download cancelled during metadata resolution',
          ));
        }
      }

      cancelToken?.whenCancel.then((_) => handleCancel());
      if (cancelToken?.isCancelled == true) {
        handleCancel();
        return completer.future;
      }

      sub = TorrentService.torrentUpdates.listen((torrents) {
        final torrent = torrents[torrentId];
        if (torrent != null && torrent.hasMetadata && !completer.isCompleted) {
          metadataTimer?.cancel();
          sub?.cancel();
          final files = TorrentService.getFiles(torrentId);
          final resolvedFiles = files
              .map((f) => {
                    'name': f.name,
                    'length': f.size,
                    'selected': true,
                    'priority': 4,
                    'downloadedBytes': 0,
                    'speed': 0.0,
                  })
              .toList();
          final totalSize = resolvedFiles.fold<int>(
              0, (sum, f) => sum + (f['length'] as int));
          try {
            TorrentService.pauseTorrent(torrentId);
            TorrentService.removeTorrent(torrentId, deleteFiles: false);
          } catch (_) {}
          completer.complete(DownloadMetadata(
            fileName: torrent.name,
            category: categoryFromFileName(torrent.name),
            fileSize: totalSize,
            supportsResume: true,
            torrentFiles: resolvedFiles,
          ));
        }
      });
      metadataTimer = Timer(const Duration(seconds: 60), () {
        if (completer.isCompleted) return;
        sub?.cancel();
        try {
          TorrentService.pauseTorrent(torrentId);
          TorrentService.removeTorrent(torrentId, deleteFiles: false);
        } catch (_) {}
        completer.complete(DownloadMetadata(
          fileName: resolvedName,
          category: 'Torrent',
          fileSize: 0,
          supportsResume: true,
        ));
      });
      return completer.future;
    }

    // file:// .torrent
    var fileName = requestedFileName?.trim().isNotEmpty == true
        ? safeFileName(requestedFileName!.trim())
        : 'torrent_download.zip';
    var fileSize = 0;
    List<Map<String, dynamic>>? torrentFiles;
    if (url.startsWith('file://')) {
      final file = File(Uri.parse(url).toFilePath());
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final meta = await compute(BencodeDecoder.parseTorrentBytes, bytes);
        if (meta != null) {
          fileName = meta['name'] ?? fileName;
          fileSize = meta['length'] ?? fileSize;
          torrentFiles = (meta['files'] as List? ?? []).map((f) {
            final fileMap = f as Map;
            return {
              'name': fileMap['name'] as String? ?? '',
              'length': fileMap['length'] as int? ?? 0,
              'selected': true,
              'priority': 4,
              'downloadedBytes': 0,
              'speed': 0.0,
            };
          }).toList();
          if (fileSize == 0) {
            fileSize = torrentFiles.fold<int>(
                0, (sum, f) => sum + ((f['length'] as int?) ?? 0));
          }
        }
      }
    }
    return DownloadMetadata(
      fileName: fileName,
      category: 'Torrent',
      fileSize: fileSize,
      supportsResume: true,
      torrentFiles: torrentFiles,
    );
  }

  // ── Speed limits / disk space ────────────────────────────────────────────

  void updateSpeedLimit(int bytesPerSecond, int activeCount) {
    TorrentService.setDownloadLimit(bytesPerSecond);
    _pool?.updateSpeedLimit(bytesPerSecond, activeCount);
  }

  Future<bool> hasEnoughDiskSpace(String savePath, int requiredBytes) async {
    try {
      final requiredWithMargin = (requiredBytes * 1.1).toInt();
      final dir = Directory(savePath);
      if (!await dir.exists()) await dir.create(recursive: true);
      final stat = await _getDiskSpace(savePath);
      if (stat == null) return true;
      return stat.freeBytes >= requiredWithMargin;
    } catch (e) {
      debugPrint('[DownloadEngine] disk space check failed: $e');
      return true;
    }
  }

  Future<void> checkLowStorageWarning(String savePath) async {
    try {
      final info = await _getDiskSpace(savePath);
      if (info != null && info.freeBytes < _lowSpaceThresholdBytes) {
        debugPrint('[DownloadEngine] WARNING: low disk space: '
            '${(info.freeBytes / 1024 / 1024).toStringAsFixed(0)} MB remaining');
      }
    } catch (_) {}
  }

  Future<_DiskSpaceInfo?> _getDiskSpace(String path) async {
    try {
      if (Platform.isAndroid || Platform.isLinux || Platform.isMacOS) {
        final result = await Process.run('df', ['-B1', path]);
        if (result.exitCode != 0) return null;
        final lines = (result.stdout as String).trim().split('\n');
        if (lines.length < 2) return null;
        final parts = lines[1].trim().split(RegExp(r'\s+'));
        if (parts.length < 4) return null;
        return _DiskSpaceInfo(freeBytes: int.tryParse(parts[3]) ?? 0);
      }
      return null;
    } catch (_) {
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
    if (requestedThreads <= 1) return 1;
    if (fileSize > 0 && fileSize < ChunkScheduler.minSizeForMultithread) {
      return 1;
    }
    final client = dio ?? _sharedDio;
    try {
      final response = await client.head(
        url,
        cancelToken: cancelToken,
        options: Options(
          headers: const {'Range': 'bytes=0-0'},
          validateStatus: (_) => true,
        ),
      );
      if (response.headers.value('accept-ranges') == 'none') return 1;
      if (response.headers.value('connection')?.toLowerCase() == 'close') {
        return 1;
      }
      return requestedThreads;
    } catch (_) {
      return requestedThreads;
    }
  }

  // ── Paths / cleanup ──────────────────────────────────────────────────────

  String buildLocalFilePath(String directory, String fileName) {
    final safeName = safeFileName(fileName);
    final fullPath = p.join(directory, safeName);
    if (!p.isWithin(directory, fullPath)) {
      throw ArgumentError('Invalid file name: path traversal detected');
    }
    return fullPath;
  }

  String buildTempFilePath(String directory, String fileName) {
    return p.join(directory, '${safeFileName(fileName)}.dmxpart');
  }

  /// Deletes temp/sidecar files for a task. Merge sources (.audio*) are only
  /// removed when [mergeConfirmed] — callers that have not verified a
  /// successful merge can never delete the inputs, so a failed merge stays
  /// retryable without re-downloading.
  static Future<void> cleanupOrphanFiles(
    String tempFilePath, {
    bool mergeConfirmed = false,
  }) async {
    if (tempFilePath.trim().isEmpty) return;
    try {
      final dir = File(tempFilePath).parent;
      if (!await dir.exists()) return;
      final baseWithoutExt = p.withoutExtension(tempFilePath);
      final patterns = <String>{
        tempFilePath,
        '$tempFilePath.dmxstate',
        '$baseWithoutExt.dmxstate',
        '$tempFilePath.dmxstate.tmp',
        '$tempFilePath.journal',
        '$baseWithoutExt.journal',
      };
      if (mergeConfirmed) {
        patterns.addAll({
          '$tempFilePath.audio',
          '$baseWithoutExt.audio',
          '$tempFilePath.audio.dmxstate',
          '$baseWithoutExt.audio.dmxstate',
          '$tempFilePath.audio.journal',
          '$baseWithoutExt.audio.journal',
          '$tempFilePath.merged',
          '$baseWithoutExt.merged',
        });
      }
      for (final path in patterns) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (e) {
          debugPrint('[DownloadEngine] cleanup failed for $path: $e');
        }
      }
      final stem = p.basenameWithoutExtension(tempFilePath);
      await for (final entity in dir.list()) {
        if (entity is File &&
            entity.path.contains('$stem.part') &&
            entity.path != tempFilePath) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[DownloadEngine] cleanupOrphanFiles error: $e');
    }
  }

  // ── Main entry point (signature preserved) ──────────────────────────────

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
    bool enableProxy = false,
    String? proxyAddress,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool bypassSSL = false,
    String? cookies,
    String? oauthToken,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int? torrentId,
    bool isNameAutoGenerated = false,
    List<String>? mirrorUrls,
    bool adaptiveThreads = false,
    int speedLimitKbps = 0,
  }) async {
    _activeCancelTokens.add(cancelToken);

    final int defaultCount =
        SettingsProvider.instance.effectiveDefaultThreadCount;
    final int effectiveThreadCount =
        (threadCount > 0 ? threadCount : defaultCount)
            .clamp(1, PowerMonitor.maxAllowedThreads);

    int resolvedFileSize = knownFileSize;
    bool resolvedSupportsResume = supportsResume;
    String? resolvedFileName;

    final isTorrent = isTorrentUrl(url, fileName: p.basename(localFilePath));

    if (!isTorrent && resolvedFileSize == 0 && isNameAutoGenerated) {
      try {
        final meta = await resolveMetadata(
          url: url,
          customUserAgent: customUserAgent,
          referer: referer,
          enableProxy: enableProxy,
          proxyAddress: proxyAddress,
          proxyHost: proxyHost,
          proxyPort: proxyPort,
          proxyUsername: proxyUsername,
          proxyPassword: proxyPassword,
          bypassSSL: bypassSSL,
          cookies: cookies,
          oauthToken: oauthToken,
        );
        resolvedFileSize = meta.fileSize;
        resolvedSupportsResume = meta.supportsResume;
        resolvedFileName = meta.fileName;
      } catch (e) {
        debugPrint('[DownloadEngine] resolveMetadata failed: $e');
      }
      if (resolvedFileName != null || resolvedFileSize > 0) {
        onProgress(DownloadProgress(
          downloadedBytes: 0,
          fileSize: resolvedFileSize,
          speed: 0.0,
          eta: null,
          fileName: resolvedFileName,
          supportsResume: resolvedSupportsResume,
        ));
      }
    }

    // Disk-space gate: only the REMAINING bytes matter for resumes.
    if (resolvedFileSize > 0) {
      final saveDir = Directory(localFilePath).parent.path;
      int alreadyOnDisk = 0;
      try {
        final state = await StateStore.loadOrCreate(
          tempFilePath,
          url: url,
          threadCount: effectiveThreadCount,
          knownFileSize: resolvedFileSize,
        );
        alreadyOnDisk = state.state.downloadedBytes;
      } catch (_) {}
      final remaining =
          (resolvedFileSize - alreadyOnDisk).clamp(0, resolvedFileSize);
      if (!await hasEnoughDiskSpace(saveDir, remaining)) {
        _activeCancelTokens.remove(cancelToken);
        throw const InsufficientStorageException();
      }
      await checkLowStorageWarning(saveDir);
    }

    if (isTorrent) {
      try {
        await _handleTorrentDownload(
          url: url,
          currentLocalFilePath: localFilePath,
          knownFileSize: resolvedFileSize,
          cancelToken: cancelToken,
          onProgress: onProgress,
          getTorrentFiles: getTorrentFiles,
          torrentId: torrentId,
          enableProxy: enableProxy,
          proxyAddress: proxyAddress,
          proxyHost: proxyHost,
          proxyPort: proxyPort,
          proxyUsername: proxyUsername,
          proxyPassword: proxyPassword,
          bypassSSL: bypassSSL,
        );
      } finally {
        _activeCancelTokens.remove(cancelToken);
      }
      return;
    }

    var finalUrl = url.replaceAll(RegExp(r'(?<=[?&])range=[^&]*&?'), '');
    if (finalUrl.endsWith('?') || finalUrl.endsWith('&')) {
      finalUrl = finalUrl.substring(0, finalUrl.length - 1);
    }
    final punyUrl = convertIdnToPunycode(finalUrl);

    final command = DownloadCommand(
      taskId: taskId,
      url: url,
      punyUrl: punyUrl,
      tempFilePath: tempFilePath,
      localFilePath: localFilePath,
      knownFileSize: resolvedFileSize,
      supportsResume: resolvedSupportsResume,
      threadCount: effectiveThreadCount,
      customUserAgent: customUserAgent,
      referer: referer,
      enableProxy: enableProxy,
      proxyAddress: proxyAddress,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
      bypassSSL: bypassSSL,
      cookies: cookies,
      oauthToken: oauthToken,
      isNameAutoGenerated: isNameAutoGenerated,
      initialSpeedLimit: speedLimitBytesPerSecond(),
      initialActiveCount: activeDownloadCount(),
      mirrorUrls: mirrorUrls,
      adaptiveThreads: adaptiveThreads,
      speedLimitKbps: speedLimitKbps,
      resolvedFileName: resolvedFileName,
    );

    final pool = await _ensurePool();
    final job = pool.submit(command);
    final completer = Completer<void>();
    bool acked = false;
    bool cancelRequested = false;
    Timer? watchdog;
    Timer? inactivityTimer;

    void resetInactivityTimer() {
      inactivityTimer?.cancel();
      inactivityTimer = Timer(const Duration(minutes: 30), () {
        if (!completer.isCompleted) {
          completer.completeError(DioException(
            requestOptions: RequestOptions(path: punyUrl),
            type: DioExceptionType.receiveTimeout,
            message: 'Download job timed out after 30 minutes of inactivity.',
          ));
        }
      });
    }

    resetInactivityTimer();
    watchdog = Timer(const Duration(seconds: 30), () {
      if (!acked && !completer.isCompleted) {
        inactivityTimer?.cancel();
        completer.completeError(const IsolateSpawnTimeoutException());
      }
    });

    void requestCancel() {
      cancelRequested = true;
      job.cancel();
    }

    cancelToken.whenCancel.then((_) => requestCancel());
    if (cancelToken.isCancelled) requestCancel();

    final sub = job.messages.listen((message) {
      switch (message.type) {
        case 'ack':
          acked = true;
          if (cancelRequested) job.cancel();
        case 'progress':
          resetInactivityTimer();
          final p = message.data;
          onProgress(DownloadProgress(
            downloadedBytes: (p['downloadedBytes'] as num?)?.toInt() ?? 0,
            fileSize: (p['fileSize'] as num?)?.toInt() ?? 0,
            speed: (p['speed'] as num?)?.toDouble() ?? 0.0,
            eta: (p['eta'] as num?)?.toInt(),
            chunks: p['chunks'] != null
                ? List<double>.from(p['chunks'] as List)
                : null,
            fileName: p['fileName'] as String?,
            supportsResume: p['supportsResume'] as bool?,
            statusMessage: p['statusMessage'] as String?,
          ));
        case 'done':
          inactivityTimer?.cancel();
          if (!completer.isCompleted) completer.complete();
        case 'error':
          inactivityTimer?.cancel();
          if (!completer.isCompleted) {
            completer.completeError(_mapWorkerError(message, punyUrl));
          }
      }
    });

    try {
      await completer.future;
    } finally {
      watchdog.cancel();
      inactivityTimer?.cancel();
      await sub.cancel();
      job.dispose();
      _activeCancelTokens.remove(cancelToken);
    }
  }

  /// Maps versioned worker error payloads back to typed exceptions.
  Object _mapWorkerError(EngineMessage message, String url) {
    final data = message.data;
    final errType = data['errorType'] as String? ?? 'uncaught';
    final errMsg = data['errorMessage']?.toString() ?? 'Unknown engine error';
    final errStatus = data['errorStatus'] as int?;

    switch (errType) {
      case 'integrity':
        return DownloadIntegrityException(errMsg);
      case 'diskFull':
        return const InsufficientStorageException();
      case 'fileChanged':
        return DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.unknown,
          message: errMsg, // contains 'File changed on server'
        );
      case 'workerDied':
        return DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.unknown,
          message: 'Download engine worker crashed: $errMsg',
        );
      default:
        final DioExceptionType dioType = switch (errType) {
          'cancel' => DioExceptionType.cancel,
          'badResponse' => DioExceptionType.badResponse,
          'connectionTimeout' => DioExceptionType.connectionTimeout,
          'receiveTimeout' => DioExceptionType.receiveTimeout,
          'sendTimeout' => DioExceptionType.sendTimeout,
          'connectionError' => DioExceptionType.connectionError,
          _ => DioExceptionType.unknown,
        };
        return DioException(
          requestOptions: RequestOptions(path: url),
          type: dioType,
          message: errMsg,
          response: errStatus != null
              ? Response(
                  requestOptions: RequestOptions(path: url),
                  statusCode: errStatus,
                )
              : null,
        );
    }
  }

  // ── Torrent orchestration (engine side) ─────────────────────────────────

  Future<void> _handleTorrentDownload({
    required String url,
    required String currentLocalFilePath,
    required int knownFileSize,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int? torrentId,
    bool enableProxy = false,
    String? proxyAddress,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool bypassSSL = false,
  }) async {
    int id = torrentId ?? -1;
    if (id >= 0 && !TorrentService.isTorrentAlive(id)) {
      debugPrint('[DMX] Stale torrent handle $id detected; re-adding.');
      id = -1;
    }
    if (id == -1) {
      final saveDir = File(currentLocalFilePath).parent.path;
      if (url.startsWith('magnet:')) {
        id = TorrentService.addMagnet(url, saveDir);
      } else {
        String filePath = url;
        if (url.startsWith('file://')) {
          filePath = Uri.parse(url).toFilePath();
        } else if (url.startsWith('http://') || url.startsWith('https://')) {
          final tempTorrentPath = p.join(
            Directory.systemTemp.path,
            'temp_${DateTime.now().millisecondsSinceEpoch}.torrent',
          );
          final tempTorrentFile = File(tempTorrentPath);
          final torrentDio = _buildIsolatedClient(
            url: url,
            enableProxy: enableProxy,
            proxyAddress: proxyAddress,
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            proxyUsername: proxyUsername,
            proxyPassword: proxyPassword,
            bypassSSL: bypassSSL,
          );
          try {
            await torrentDio.download(url, tempTorrentPath);
            filePath = tempTorrentPath;
            id = TorrentService.addTorrentFile(filePath, saveDir,
                sourceKey: url);
          } finally {
            _releaseClient(torrentDio);
            try {
              if (await tempTorrentFile.exists()) {
                await tempTorrentFile.delete();
              }
            } catch (_) {}
          }
        } else {
          id = TorrentService.addTorrentFile(filePath, saveDir, sourceKey: url);
        }
      }
    }
    if (id < 0) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.unknown,
        error: 'Torrent engine rejected the torrent.',
      );
    }

    TorrentResumeStore.registerSource(id, url);
    _activeTorrentIds.add(id);

    try {
      await _waitForMetadata(id, url, cancelToken, onProgress,
          initialFileSize: knownFileSize);

      _applyFilePriorities(id, getTorrentFiles?.call());

      // RESUME BARRIER (load side): fast-resume data is loaded, hash-verified
      // and applied BEFORE the torrent is resumed and BEFORE any progress
      // number can be emitted. Without usable resume data we recheck and wait
      // for the checking state to finish — still before any progress number.
      final resumeBlob = await TorrentResumeStore.loadResumeDataForSource(url);
      final nativeLoaded =
          resumeBlob != null && TorrentService.loadResumeData(id, resumeBlob);
      if (!nativeLoaded) {
        if (resumeBlob != null) {
          debugPrint(
              '[DMX] stored resume data rejected by engine — rechecking');
        }
        TorrentService.recheckTorrent(id);
        await _waitForState(
          id,
          cancelToken,
          predicate: (label) =>
              !label.contains('checking') &&
              !label.contains('metadata') &&
              !label.contains('allocating'),
          timeout: const Duration(minutes: 5),
        );
      }
      if (cancelToken.isCancelled) return;

      TorrentService.resumeTorrent(id);
      await _listenForCompletion(
        id,
        url,
        cancelToken,
        onProgress,
        getTorrentFiles,
        knownFileSize,
      );
    } finally {
      _activeTorrentIds.remove(id);
    }
  }

  Future<void> _waitForMetadata(
    int id,
    String url,
    CancelToken cancelToken,
    ValueChangedProgress onProgress, {
    int initialFileSize = 0,
  }) async {
    final completer = Completer<void>();
    StreamSubscription? sub;
    Timer? heartbeat;
    var elapsed = 0;

    sub = TorrentService.torrentUpdates.listen((torrents) {
      final torrent = torrents[id];
      if (torrent != null && torrent.hasMetadata && !completer.isCompleted) {
        completer.complete();
      }
    });
    cancelToken.whenCancel.then((_) {
      if (!completer.isCompleted) {
        try {
          TorrentService.removeTorrent(id, deleteFiles: false);
        } catch (_) {}
        completer.completeError(DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.cancel,
          error: 'cancelled',
        ));
      }
    });
    heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      if (completer.isCompleted) return;
      elapsed += 30;
      onProgress(DownloadProgress(
        downloadedBytes: 0,
        fileSize: 0,
        speed: 0,
        eta: null,
        statusMessage: 'Fetching metadata… (${elapsed}s elapsed)',
      ));
    });
    final timeout = Timer(const Duration(seconds: 300), () {
      if (completer.isCompleted) return;
      sub?.cancel();
      if (!cancelToken.isCancelled) {
        try {
          TorrentService.removeTorrent(id, deleteFiles: false);
        } catch (_) {}
      }
      completer.completeError(DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.receiveTimeout,
        error: 'Timed out waiting for torrent metadata.',
      ));
    });
    try {
      await completer.future;
    } finally {
      heartbeat.cancel();
      timeout.cancel();
      await sub.cancel();
    }
  }

  void _applyFilePriorities(
      int id, List<Map<String, dynamic>>? currentTorrentFiles) {
    if (currentTorrentFiles == null || currentTorrentFiles.isEmpty) return;
    final engineFileCount = TorrentService.getFileCount(id);
    if (engineFileCount != currentTorrentFiles.length) return;
    final priorities = currentTorrentFiles.map((f) {
      final selected = f['selected'] as bool? ?? true;
      if (!selected) return 0;
      return f['priority'] as int? ?? 4;
    }).toList();
    TorrentService.setFilePriorities(id, priorities);
  }

  Future<void> _listenForCompletion(
    int id,
    String url,
    CancelToken cancelToken,
    ValueChangedProgress onProgress,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int knownFileSize,
  ) async {
    final completer = Completer<void>();
    StreamSubscription? sub;

    sub = TorrentService.torrentUpdates.listen((torrents) {
      final torrent = torrents[id];
      if (torrent == null || completer.isCompleted) return;
      final stateLabel = torrent.stateLabel.toLowerCase();

      // NEVER emit progress numbers while resume data is being verified.
      final isCheckingOrMetadata = stateLabel.contains('checking') ||
          stateLabel.contains('metadata') ||
          stateLabel.contains('allocating');

      List<Map<String, dynamic>>? resolvedFiles;
      String? resolvedName;
      if (torrent.hasMetadata) {
        resolvedName = torrent.name;
        try {
          final files = TorrentService.getFiles(id);
          final existingFiles = getTorrentFiles?.call() ?? [];
          resolvedFiles = files.map((f) {
            final existing = existingFiles
                .cast<Map<String, dynamic>?>()
                .firstWhere((e) => (e?['name'] as String?) == f.name,
                    orElse: () => null);
            int resolvedBytes;
            bool isEstimated;
            if (f.downloadedBytes >= 0) {
              resolvedBytes = f.size > 0
                  ? f.downloadedBytes.clamp(0, f.size)
                  : f.downloadedBytes;
              isEstimated = false;
            } else {
              resolvedBytes = 0;
              isEstimated = true;
            }
            return <String, dynamic>{
              'name': f.name,
              'length': f.size,
              'selected': existing?['selected'] as bool? ?? f.selected,
              'priority': existing?['priority'] as int? ?? f.priority,
              'downloadedBytes': resolvedBytes,
              'speed': 0.0,
              'progressEstimated': isEstimated,
            };
          }).toList();
        } catch (e) {
          debugPrint('[DownloadEngine] getFiles failed: $e');
        }
      }

      final int calculatedTotal = (resolvedFiles != null)
          ? resolvedFiles
              .where((f) => f['selected'] == true)
              .fold<int>(0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0))
          : 0;
      final totalSize = torrent.totalWanted > 0
          ? torrent.totalWanted
          : (calculatedTotal > 0
              ? calculatedTotal
              : (knownFileSize > 0 ? knownFileSize : 0));

      if (!torrent.hasMetadata && totalSize <= 0) {
        onProgress(DownloadProgress(
          downloadedBytes: 0,
          fileSize: 0,
          speed: 0,
          eta: null,
          statusMessage: 'Fetching metadata…',
          fileName: resolvedName,
        ));
        return;
      }

      final rawDownloaded = torrent.totalWantedDone > 0
          ? torrent.totalWantedDone
          : torrent.totalDone;
      final downloadedBytes =
          totalSize > 0 ? min(rawDownloaded, totalSize) : rawDownloaded;

      if (resolvedFiles != null) {
        _distributeEstimatedBytes(resolvedFiles, downloadedBytes);
        final maxConcurrent =
            SettingsProvider.instance.maxConcurrentFilesPerTorrent;
        if (maxConcurrent > 0 && !isCheckingOrMetadata) {
          _applyMaxConcurrentFilesLimit(id, resolvedFiles, maxConcurrent);
        }
      }

      final isUserPaused = stateLabel == 'paused' || stateLabel == 'stopped';
      if (isUserPaused && !cancelToken.isCancelled && !isCheckingOrMetadata) {
        onProgress(DownloadProgress(
          downloadedBytes: downloadedBytes,
          fileSize: totalSize,
          speed: 0.0,
          eta: null,
          fileName: resolvedName,
          torrentFiles: resolvedFiles,
          supportsResume: true,
        ));
        if (!completer.isCompleted) completer.complete();
        return;
      }

      final isStableFinished = stateLabel == 'seeding' ||
          stateLabel == 'completed' ||
          stateLabel == 'finished';
      final isFullyDownloaded =
          totalSize > 0 ? downloadedBytes >= totalSize : isStableFinished;
      final isCompleted =
          isFullyDownloaded && !isCheckingOrMetadata && isStableFinished;

      final speed = torrent.downloadRate.toDouble();
      final remaining =
          totalSize > downloadedBytes ? totalSize - downloadedBytes : 0;
      final eta = speed.isFinite && speed > 0 && remaining > 0
          ? (remaining / speed).round().clamp(0, 86400 * 365)
          : null;

      if (!isCheckingOrMetadata) {
        onProgress(DownloadProgress(
          downloadedBytes: downloadedBytes,
          fileSize: totalSize,
          speed: speed,
          eta: eta,
          fileName: resolvedName,
          torrentFiles: resolvedFiles,
        ));
      }
      if (isCompleted && !completer.isCompleted) completer.complete();
    });

    cancelToken.whenCancel.then((_) async {
      await sub?.cancel();
      // PAUSE BARRIER (engine side): flush and hash-verify fast-resume data
      // BEFORE the cancel completes, so "cancelled" always implies
      // "resumable state is on disk".
      try {
        await TorrentResumeStore.saveAndWait(
          torrentId: id,
          sourceUrl: url,
          fetchResumeData: () => TorrentService.progressFor(id),
          files: getTorrentFiles?.call(),
        );
      } catch (e) {
        debugPrint('[DMX] cancel-time resume save failed: $e');
      }
      try {
        TorrentService.pauseTorrent(id);
      } catch (_) {}
      if (!completer.isCompleted) {
        completer.completeError(DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.cancel,
          message: 'Torrent download cancelled by user.',
        ));
      }
    });

    try {
      await completer.future;
    } finally {
      await sub.cancel();
    }
  }

  static final Map<int, DateTime> _lastConcurrentLimitApply = {};
  static final Map<int, Set<int>> _lastIncompleteSnapshot = {};
  static const Duration _concurrentLimitThrottle = Duration(seconds: 2);

  static void _applyMaxConcurrentFilesLimit(
    int torrentId,
    List<Map<String, dynamic>> files,
    int maxConcurrentFiles,
  ) {
    if (maxConcurrentFiles <= 0) return;
    final sortedIndices = List.generate(files.length, (i) => i)
      ..sort((a, b) {
        final pa = (files[a]['priority'] as int?) ?? 4;
        final pb = (files[b]['priority'] as int?) ?? 4;
        if (pa != pb) return pb.compareTo(pa);
        return a.compareTo(b);
      });
    final incompleteSelected = <int>[];
    final incompleteSet = <int>{};
    for (final idx in sortedIndices) {
      final f = files[idx];
      final selected = f['selected'] as bool? ?? true;
      final length = (f['length'] as num?)?.toInt() ?? 0;
      final downloaded = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      if (selected && downloaded < length) {
        incompleteSelected.add(idx);
        incompleteSet.add(idx);
      }
    }
    final now = DateTime.now();
    final lastApply = _lastConcurrentLimitApply[torrentId];
    final prev = _lastIncompleteSnapshot[torrentId];
    var fileCompleted = false;
    if (prev != null) {
      for (final idx in prev) {
        if (!incompleteSet.contains(idx)) {
          fileCompleted = true;
          break;
        }
      }
    }
    if (!fileCompleted &&
        lastApply != null &&
        now.difference(lastApply) < _concurrentLimitThrottle) {
      return;
    }
    final priorities = List.filled(files.length, 0);
    for (var i = 0; i < incompleteSelected.length; i++) {
      final idx = incompleteSelected[i];
      priorities[idx] =
          i < maxConcurrentFiles ? ((files[idx]['priority'] as int?) ?? 4) : 0;
    }
    _lastConcurrentLimitApply[torrentId] = now;
    _lastIncompleteSnapshot[torrentId] = incompleteSet;
    TorrentService.setFilePriorities(torrentId, priorities);
  }

  static void _distributeEstimatedBytes(
      List<Map<String, dynamic>> files, int downloadedBytes) {
    final needing = files
        .where((f) => (f['progressEstimated'] as bool? ?? true) == true)
        .toList();
    if (needing.isEmpty || downloadedBytes <= 0) return;
    final confirmed = files
        .where((f) => (f['progressEstimated'] as bool? ?? true) == false)
        .fold<int>(0, (s, f) => s + ((f['downloadedBytes'] as int?) ?? 0));
    final remaining = (downloadedBytes - confirmed).clamp(0, downloadedBytes);
    final selectedSize = needing.fold<int>(
        0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0));
    if (selectedSize <= 0) return;
    for (final f in needing) {
      final len = (f['length'] as num?)?.toInt() ?? 0;
      final share = selectedSize > 0
          ? (remaining * (len / selectedSize)).round().clamp(0, len)
          : 0;
      f['downloadedBytes'] = share;
    }
  }

  Future<void> _waitForState(
    int id,
    CancelToken cancelToken, {
    required bool Function(String stateLabel) predicate,
    required Duration timeout,
  }) async {
    final completer = Completer<void>();
    StreamSubscription? sub;
    Timer? t;
    String? lastSeen;
    sub = TorrentService.torrentUpdates.listen((torrents) {
      final tor = torrents[id];
      if (tor != null) {
        lastSeen = tor.stateLabel;
        if (predicate(tor.stateLabel.toLowerCase()) && !completer.isCompleted) {
          completer.complete();
        }
      }
    });
    t = Timer(timeout, () {
      if (completer.isCompleted) return;
      try {
        TorrentService.pauseTorrent(id);
      } catch (_) {}
      completer.completeError(DioException(
        requestOptions: RequestOptions(path: 'torrent:$id'),
        type: DioExceptionType.receiveTimeout,
        message:
            'Torrent state check timed out (last: "$lastSeen"). Download paused for safety.',
      ));
    });
    cancelToken.whenCancel.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(DioException(
          requestOptions: RequestOptions(path: 'torrent:$id'),
          type: DioExceptionType.cancel,
          error: 'cancelled',
        ));
      }
    });
    try {
      await completer.future;
    } finally {
      t.cancel();
      await sub.cancel();
    }
  }

  void close() {
    _closed = true;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    for (final token in List<CancelToken>.from(_activeCancelTokens)) {
      try {
        token.cancel('Engine closing');
      } catch (_) {}
    }
    _activeCancelTokens.clear();
    _sharedDio.close(force: true);
    for (final client in List<Dio>.from(_activeDioClients)) {
      try {
        client.close(force: true);
      } catch (_) {}
    }
    _activeDioClients.clear();
    _reservedDioClients.clear();
    _dioClientCreationTimes.clear();
    _activeDownloadsPerClient.clear();
    final poolToClose = _pool;
    _pool = null;
    _poolInit = null;
    if (poolToClose != null) {
      unawaited(poolToClose.shutdown().catchError((_) {}));
    }
    for (final id in List<int>.from(_activeTorrentIds)) {
      try {
        TorrentService.pauseTorrent(id);
      } catch (_) {}
    }
    _activeTorrentIds.clear();
    _httpEngine.stopAdaptiveThreadMonitor();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SHARED HELPERS
// ═══════════════════════════════════════════════════════════════════════════

/// Builds a transfer-configured Dio client. Isolate-safe (no shared state),
/// used both by main-isolate probes and by worker isolates.
Dio buildTransferDio({
  String? url,
  String? customUserAgent,
  String? referer,
  bool enableProxy = false,
  String? proxyAddress,
  String? proxyHost,
  int? proxyPort,
  String? proxyUsername,
  String? proxyPassword,
  bool bypassSSL = false,
  String? cookies,
  String? oauthToken,
}) {
  final client = Dio();
  client.interceptors.add(ProfessionalRetryInterceptor(client));
  client.options.connectTimeout = const Duration(seconds: 30);
  client.options.sendTimeout = const Duration(seconds: 60);
  client.options.receiveTimeout = const Duration(seconds: 60);

  final uri = url != null ? Uri.tryParse(url) : null;
  final host = uri?.host.toLowerCase() ?? '';
  final isYoutubeUrl = host.contains('youtube.com') ||
      host == 'youtu.be' ||
      host.endsWith('.googlevideo.com');

  if (isYoutubeUrl) {
    client.options.headers['Origin'] = 'https://www.youtube.com';
    client.options.headers['Referer'] = (referer != null && referer.isNotEmpty)
        ? referer
        : 'https://www.youtube.com/';
    client.options.headers['User-Agent'] =
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';
    client.options.headers['Accept'] = '*/*';
    client.options.headers['Accept-Language'] = 'en-US,en;q=0.9';
    if (oauthToken != null && oauthToken.isNotEmpty) {
      client.options.headers['Authorization'] = 'Bearer $oauthToken';
    }
  } else if (customUserAgent != null && customUserAgent.trim().isNotEmpty) {
    client.options.headers['User-Agent'] = customUserAgent.trim();
  } else {
    client.options.headers['User-Agent'] =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  }
  if (referer != null &&
      referer.isNotEmpty &&
      !client.options.headers.containsKey('Referer')) {
    client.options.headers['Referer'] = referer;
  }
  if (cookies != null && cookies.isNotEmpty) {
    client.options.headers['Cookie'] = cookies;
  }

  if (client.httpClientAdapter is IOHttpClientAdapter) {
    final adapter = client.httpClientAdapter as IOHttpClientAdapter;
    final String proxyHostResolved =
        (enableProxy && proxyHost != null && proxyHost.trim().isNotEmpty)
            ? proxyHost.trim()
            : (enableProxy && proxyAddress != null && proxyAddress.contains(':')
                ? proxyAddress.split(':')[0].trim()
                : (enableProxy ? proxyAddress?.trim() ?? '' : ''));
    final int port = (enableProxy && proxyPort != null && proxyPort > 0)
        ? proxyPort
        : (enableProxy && proxyAddress != null && proxyAddress.contains(':')
            ? int.tryParse(proxyAddress.split(':')[1]) ?? 8080
            : 8080);
    adapter.createHttpClient = () {
      final httpClient = HttpClient();
      if (enableProxy && proxyHostResolved.isNotEmpty) {
        httpClient.findProxy = (uri) => 'PROXY $proxyHostResolved:$port';
        if (proxyUsername != null && proxyUsername.isNotEmpty) {
          httpClient.authenticateProxy = (h, p, scheme, realm) async {
            httpClient.addProxyCredentials(h, p, realm ?? '',
                HttpClientBasicCredentials(proxyUsername, proxyPassword ?? ''));
            return true;
          };
        }
      }
      if (bypassSSL) {
        httpClient.badCertificateCallback = (cert, h, p) => true;
      }
      return httpClient;
    };
  }
  return client;
}

/// THE single byte-counting entry point used by orchestrator/provider.
/// Loads (migrating if needed), reconciles against disk, returns proven bytes.
Future<int> actualDownloadedBytes(
  String path, {
  required int threadCount,
}) async {
  try {
    final result = await StateStore.loadOrCreate(
      path,
      url: '',
      threadCount: threadCount,
      knownFileSize: 0,
    );
    return result.state.downloadedBytes;
  } catch (e) {
    debugPrint('[DMX] actualDownloadedBytes failed for $path: $e');
    if (threadCount <= 1) {
      final f = File(path);
      if (await f.exists()) return f.length();
    }
    return 0;
  }
}

String _redactUrl(String? url) {
  if (url == null || url.isEmpty) return '<empty>';
  final uri = Uri.tryParse(url);
  if (uri == null) return '<invalid-url>';
  final host = uri.host.isEmpty ? '<host>' : uri.host;
  final port = uri.hasPort ? ':${uri.port}' : '';
  final redactedPath = uri.path
      .split('/')
      .map((s) => _looksLikePathToken(s) ? '<redacted>' : s)
      .join('/');
  return '${uri.scheme.isEmpty ? 'https' : uri.scheme}://$host$port'
      '$redactedPath${uri.hasQuery ? '?<redacted>' : ''}';
}

bool _looksLikePathToken(String segment) {
  if (segment.isEmpty || segment.length < 24) return false;
  if (!RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(segment)) return false;
  return segment.contains(RegExp(r'[0-9]'));
}

String? _firstNonEmpty(String? a, String? b) {
  if (a != null && a.trim().isNotEmpty) return a;
  if (b != null && b.trim().isNotEmpty) return b;
  return null;
}

class _DiskSpaceInfo {
  final int freeBytes;
  const _DiskSpaceInfo({required this.freeBytes});
}
