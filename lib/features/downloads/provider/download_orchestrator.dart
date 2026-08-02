import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:webview_cookie_manager/webview_cookie_manager.dart';

import '../../../core/services/background_service.dart';
import '../../../core/services/checksum_service.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/diagnostic_service.dart';
import '../../../core/services/download_engine.dart';
import '../../../core/services/download_metrics.dart';
import '../../../core/services/error_taxonomy.dart';
import '../../../core/services/ffmpeg_mux_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/torrent_service.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/url_utils.dart';
import '../../../shared/accessibility/xdm_announcer.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';
import 'network_monitor.dart';
import 'notification_coordinator.dart';

/// Contract the [DownloadOrchestrator] needs from its host
/// (the `DownloadProvider`).
///
/// Follows the same abstract-contract idiom as the provider mixins: the
/// orchestrator only sees this narrow interface, keeping it decoupled from
/// the provider's public API and independently testable. Members that
/// already exist on the provider (mixin contracts such as [providerTasks],
/// [pumpQueue], [downloadingTasksCount]…) are reused verbatim.
abstract class DownloadOrchestratorHost {
  // Shared task/tracking state (owned by the provider).
  List<DownloadTask> get providerTasks;
  Map<String, CancelToken> get cancelTokens;
  Map<String, Future<void>> get activeFutures;
  Map<String, Timer> get retryTimers;
  Map<String, int> get retryCounts;
  Map<String, Queue<double>> get speedHistories;
  Map<String, int> get lastProgressUpdateTimes;
  Map<String, int> get lastDbSaveTimes;
  Map<String, int> get lastTorrentFileDiskSync;
  Set<String> get pendingProgressUpdates;
  Map<String, int> get ytLowSpeedCounts;
  Map<String, bool> get ytThrottlingRefreshing;
  Map<String, int> get providerTorrentIds;
  Map<String, int> get effectiveThreadOverrides;
  Map<int, TorrentUpdateInfo> get providerLatestTorrentStats;
  bool get providerDisposed;
  Map<String, DownloadMetrics> get downloadMetrics;

  // Collaborators.
  SettingsProvider get providerSettingsProvider;
  DatabaseService get providerDatabaseService;
  DownloadEngine get downloadEngine;
  NotificationCoordinator get notifications;
  NetworkMonitor get networkMonitor;

  // Derived counters (provided by the filter mixin on the provider).
  int get downloadingTasksCount;
  int get activeOrSeedingCount;

  // Behavior callbacks into the provider.
  Future<void> setTaskState(DownloadTask task);
  DownloadTask? findTaskById(String id);
  void pumpQueue();
  Future<void> flushPendingProgress(String id);
  int effectiveSpeedLimit();
  List<double> buildChunks(int threadCount, int fileSize, int downloadedBytes);
  ({int total, List<Map<String, dynamic>>? files}) scanExistingTorrentData(
    String rootPath,
    List<Map<String, dynamic>>? fileList,
  );
  Future<void> updateTaskUrlAndResume(
    String id,
    String newUrl, {
    String? newAudioUrl,
  });
  void updateTelemetryWidget();
  void providerStartWidgetTimer();
  void providerStopWidgetTimer();
  void providerNotifyListeners();
  List<Map<String, dynamic>> markTorrentFilesCompleted(
    List<Map<String, dynamic>> files,
  );
  Future<void> cleanupPartFiles(DownloadTask task);
}

/// Owns the download start/execute/merge/finalize lifecycle.
///
/// Extracted from `DownloadProvider` (Refactor A). The provider remains a
/// facade: queue pumping calls [startTask], and all shared task state stays
/// on the provider, accessed through [DownloadOrchestratorHost]. Logic was
/// moved verbatim — no behavior changes.
class DownloadOrchestrator {
  DownloadOrchestrator(this._host);

  final DownloadOrchestratorHost _host;

  static const _mediaChannel = MethodChannel('com.dmx.app/media');

  /// Records a classified, bounded diagnostic entry for [taskId]'s failure.
  void _recordDownloadFailure(String taskId, Object error) {
    final classification = ErrorTaxonomy.classify(error);
    DiagnosticService.instance.record(
      'download',
      classification.message,
      error: error,
      details: 'task=$taskId family=${classification.family.name} '
          'status=${classification.httpStatus ?? '-'} '
          'retryable=${classification.retryable}',
    );
  }

  final Set<String> _startingTaskIds = {};
  final Map<String, ({String cookie, DateTime timestamp})> _cookieCache = {};
  @visibleForTesting
  Map<String, ({String cookie, DateTime timestamp})> get cookieCache =>
      _cookieCache;
  static const int _cookieCacheMaxSize = 50;
  final Map<String, int> _ytRefreshAttempts = {};

  int get pendingStartCount => _startingTaskIds.length;

  Future<void> startTask(DownloadTask task) async {
    if (_host.cancelTokens.containsKey(task.id)) return;
    if (_startingTaskIds.contains(task.id)) return;
    _startingTaskIds.add(task.id);
    try {
      await _startTaskBody(task);
    } finally {
      _startingTaskIds.remove(task.id);
    }
  }

  /// Extract cookies and resolve YouTube stream URLs.
  /// Returns the cookie string needed for download, or null if the task
  /// was queued for retry / marked as failed (caller should return).
  Future<String?> _resolveStreamUrl(DownloadTask task) async {
    String cookieString = '';
    try {
      final cookieUrl = task.downloadPageUrl ?? task.url;
      final uri = Uri.tryParse(cookieUrl);
      if (uri != null) {
        final origin = '${uri.scheme}://${uri.host}';
        final now = DateTime.now();
        final cached = _cookieCache[origin];
        if (cached != null &&
            now.difference(cached.timestamp) < const Duration(minutes: 5)) {
          cookieString = cached.cookie;
        } else {
          final cookies = await WebviewCookieManager().getCookies(origin);
          cookieString = cookies.map((c) => '${c.name}=${c.value}').join('; ');
          _cookieCache[origin] = (cookie: cookieString, timestamp: now);
          if (_cookieCache.length >= _cookieCacheMaxSize) {
            evictStaleCookies();
          }
        }
      }
    } catch (e) {
      debugPrint('[DMX] Cookie resolution error: $e');
    }

    final youtubeUrl = task.downloadPageUrl ?? task.url;
    if (task.youtubeQualityPreset != null &&
        (youtubeUrl.contains('youtube.com/') ||
            youtubeUrl.contains('youtu.be/'))) {
      if (cookieString.isNotEmpty) {
        YoutubeService.signIn(cookieString);
      }
      try {
        final videoId = YoutubeService.extractVideoId(youtubeUrl);
        if (videoId != null) {
          final streamInfo = await YoutubeService.getStreamForVideo(
            videoId,
            task.youtubeQualityPreset,
          );
          if (streamInfo != null) {
            final type = streamInfo['type'] as String? ?? 'muxed';
            final ext = streamInfo['ext'] as String? ?? 'mp4';
            final title = streamInfo['title'] as String? ?? '';

            String resolvedFileName;
            if (type == 'combined') {
              final qLabel = streamInfo['quality'] as String? ?? 'HD';
              resolvedFileName = title.isNotEmpty
                  ? '$title [$qLabel].$ext'
                  : task.fileName;
            } else if (type == 'audio') {
              resolvedFileName = title.isNotEmpty
                  ? '$title.$ext'
                  : task.fileName;
            } else {
              final qLabel = streamInfo['quality'] as String? ?? '';
              resolvedFileName = title.isNotEmpty && qLabel.isNotEmpty
                  ? '$title [$qLabel].$ext'
                  : (title.isNotEmpty ? '$title.$ext' : task.fileName);
            }
            resolvedFileName = safeFileName(resolvedFileName);

            final resolvedLocalPath = await getUniqueFilePath(
              task.savePath,
              resolvedFileName,
            );
            final resolvedTempPath = _host.downloadEngine.buildTempFilePath(
              p.dirname(resolvedLocalPath),
              resolvedFileName,
            );

            if (type == 'combined') {
              final videoSize = streamInfo['videoSize'] as int? ?? 0;
              final audioSize = streamInfo['audioSize'] as int? ?? 0;
              final totalSize = (videoSize + audioSize) > 0
                  ? videoSize + audioSize
                  : (streamInfo['size'] as int? ?? 0);
              task = task.copyWith(
                url: streamInfo['src'] as String,
                mergedAudioUrl: streamInfo['audioSrc'] as String,
                fileSize: totalSize,
                audioSize: audioSize,
                fileName: resolvedFileName,
                localFilePath: resolvedLocalPath,
                tempFilePath: resolvedTempPath,
              );
            } else {
              task = task.copyWith(
                url: streamInfo['src'] as String,
                fileSize: streamInfo['size'] as int? ?? 0,
                fileName: resolvedFileName,
                localFilePath: resolvedLocalPath,
                tempFilePath: resolvedTempPath,
              );
            }
            await _host.setTaskState(task);
          } else if (task.url.isNotEmpty &&
              !task.url.contains('youtube.com/')) {
            debugPrint(
              '[DMX] YoutubeService.getStreamForVideo returned null; proceeding with pre-resolved stream URL.',
            );
          } else {
            throw Exception('Stream not available');
          }
        }
      } catch (e) {
        if (task.url.isNotEmpty && !task.url.contains('youtube.com/')) {
          debugPrint(
            '[DMX] YoutubeService stream resolution error ($e); proceeding with pre-resolved stream URL.',
          );
        } else {
          final isRetryable = isRetryableError(e);
          final maxRetries =
              _host.providerSettingsProvider.autoRetryEnabled && isRetryable
              ? _host.providerSettingsProvider.maxRetries
              : 0;
          final currentRetry = _host.retryCounts[task.id] ?? 0;

          if (currentRetry < maxRetries) {
            _host.retryCounts[task.id] = currentRetry + 1;
            final delaySeconds =
                _host.providerSettingsProvider.retryDelaySeconds;
            debugPrint(
              'Transient error resolving stream for task ${task.id}. Retrying (${currentRetry + 1}/$maxRetries) in $delaySeconds seconds...',
            );

            await _host.setTaskState(
              task.copyWith(
                status: DownloadStatus.queued,
                speed: 0,
                errorMessage:
                    'Retrying in $delaySeconds seconds: ${errorMessage(e)}',
              ),
            );

            _host.retryTimers[task.id]?.cancel();
            _host.retryTimers[task.id] = Timer(
              Duration(seconds: delaySeconds),
              () {
                _host.retryTimers.remove(task.id);
                if (_host.providerDisposed) return;
                final checkedTask = _host.findTaskById(task.id);
                if (checkedTask != null &&
                    checkedTask.status == DownloadStatus.queued) {
                  _host.pumpQueue();
                }
              },
            );
            return null;
          }

          _host.retryCounts.remove(task.id);
          await _host.setTaskState(
            task.copyWith(
              status: DownloadStatus.failed,
              errorMessage:
                  'Failed to resolve YouTube stream: ${errorMessage(e)}',
            ),
          );
          _host.pumpQueue();
          _host.updateTelemetryWidget();
          return null;
        }
      }
    }
    return cookieString;
  }

  /// Merge audio and video streams via FFmpeg.
  /// Returns true on success, false if no merge was needed or already handled.
  Future<bool> _mergeAudioVideo(String taskId, String audioTempPath) async {
    final current = _host.findTaskById(taskId);
    if (current == null) return false;

    final hasAudio =
        !current.isTorrent &&
        current.mergedAudioUrl != null &&
        current.mergedAudioUrl!.isNotEmpty;
    if (!hasAudio) return false;

    await _host.setTaskState(
      current.copyWith(statusMessage: DownloadStatusMessages.merging),
    );

    var actualVideoPath = current.localFilePath;
    if (!await File(actualVideoPath).exists() &&
        await File(current.tempFilePath).exists()) {
      actualVideoPath = current.tempFilePath;
    }
    var actualAudioPath = audioTempPath;
    if (!await File(actualAudioPath).exists() &&
        await File('${current.tempFilePath}.audio').exists()) {
      actualAudioPath = '${current.tempFilePath}.audio';
    }
    final videoExt = p.extension(actualVideoPath).isNotEmpty
        ? p.extension(actualVideoPath)
        : '.mp4';
    final mergedPath =
        '${p.withoutExtension(actualVideoPath)}$videoExt.merged$videoExt';

    debugPrint('[DMX] Phase 3 — Merge starting:');
    debugPrint('[DMX]   Video: $actualVideoPath');
    debugPrint('[DMX]   Audio: $actualAudioPath');
    debugPrint('[DMX]   Output: $mergedPath');

    final videoFile = File(actualVideoPath);
    final audioFile = File(actualAudioPath);

    if (!await videoFile.exists()) {
      throw Exception('Video file missing after download: $actualVideoPath');
    }
    if (!await audioFile.exists()) {
      throw Exception('Audio file missing after download: $actualAudioPath');
    }

    final videoLen = await videoFile.length();
    final audioLen = await audioFile.length();
    debugPrint('[DMX]   Video size: $videoLen bytes');
    debugPrint('[DMX]   Audio size: $audioLen bytes');

    if (videoLen == 0) {
      throw Exception('Video file is empty: $actualVideoPath');
    }
    if (audioLen == 0) {
      throw Exception('Audio file is empty: $actualAudioPath');
    }

    final success = await FFmpegMuxService.mergeVideoAudio(
      actualVideoPath,
      actualAudioPath,
      mergedPath,
      deleteInputsIfTemp: false,
    );

    if (success) {
      final mergedFile = File(mergedPath);
      if (await mergedFile.exists()) {
        final mergedLen = await mergedFile.length();
        debugPrint('[DMX] Merge successful: $mergedPath ($mergedLen bytes)');
        final targetFile = File(current.localFilePath);
        if (await targetFile.exists()) {
          try {
            await targetFile.delete();
          } catch (_) {}
        }
        try {
          await mergedFile.rename(current.localFilePath);
        } catch (e) {
          await mergedFile.copy(current.localFilePath);
          final copiedLen = await File(current.localFilePath).length();
          if (copiedLen == mergedLen) {
            await mergedFile.delete();
          } else {
            throw Exception('File copy verification failed after merge.');
          }
        }
        debugPrint('[DMX] Original video replaced with merged file');
        if (videoFile.path != current.localFilePath) {
          try {
            await videoFile.delete();
          } catch (_) {}
        }
        try {
          await audioFile.delete();
        } catch (_) {}
      } else {
        throw Exception('Merged output file not found after FFmpeg success');
      }
    } else {
      try {
        await audioFile.delete();
      } catch (_) {}
      throw Exception(
        'FFmpeg merge failed. The video-only file is saved at: $actualVideoPath',
      );
    }
    return true;
  }

  /// Finalize a completed download: SHA-256 check, status update, notification.
  Future<void> _finalizeDownload(String taskId, int notificationId) async {
    await _host.flushPendingProgress(taskId);
    _host.speedHistories.remove(taskId);
    _host.lastProgressUpdateTimes.remove(taskId);
    _host.lastDbSaveTimes.remove(taskId);

    final current = _host.findTaskById(taskId);
    _host.ytLowSpeedCounts.remove(taskId);
    _host.ytThrottlingRefreshing.remove(taskId);
    _ytRefreshAttempts.remove(taskId);
    _host.lastTorrentFileDiskSync.remove(taskId);
    if (current == null) return;
    if (current.status != DownloadStatus.downloading) return;

    // Finalize DownloadMetrics
    final metrics = _host.downloadMetrics[taskId];
    if (metrics != null) {
      metrics.markCompleted();
      metrics.totalRetries = _host.retryCounts[taskId] ?? 0;
      metrics.totalBytesDownloaded = current.downloadedBytes;
    }

    final now = DateTime.now();
    final isSeedingTorrent = current.isTorrent && current.seedingEnabled;
    if (!isSeedingTorrent && current.isTorrent) {
      final tid = _host.providerTorrentIds[current.id];
      if (tid != null) {
        TorrentService.removeTorrent(tid);
        _host.providerTorrentIds.remove(current.id);
      }
    }

    final finalFileSize = current.fileSize > 0
        ? current.fileSize
        : (current.downloadedBytes > 0 ? current.downloadedBytes : 0);

    if (current.expectedSha256 != null && current.expectedSha256!.isNotEmpty) {
      try {
        final file = File(current.localFilePath);
        // Skip SHA-256 for multi-file torrents where localFilePath is a directory.
        if (!Directory(current.localFilePath).existsSync() &&
            await file.exists()) {
          final digest = await Isolate.run(
            () => ChecksumService.sha256File(current.localFilePath),
          );
          if (digest.toLowerCase() != current.expectedSha256!.toLowerCase()) {
            await _host.setTaskState(
              current.copyWith(
                status: DownloadStatus.failed,
                errorMessage:
                    'Checksum verification failed: expected ${current.expectedSha256}, got $digest',
              ),
            );
            return;
          }
        }
      } catch (e) {
        debugPrint('[DMX] SHA-256 verification failed: $e');
        await _host.setTaskState(
          current.copyWith(
            status: DownloadStatus.failed,
            errorMessage: 'Checksum verification error: $e',
          ),
        );
        return;
      }
    }

    // Record checksum metrics
    if (metrics != null && current.expectedSha256 != null) {
      metrics.checksumAlgorithm = 'SHA-256';
      metrics.checksumVerified = true;
      metrics.checksumPassed = current.status != DownloadStatus.failed;
    }

    final hasAudio =
        !current.isTorrent &&
        current.mergedAudioUrl != null &&
        current.mergedAudioUrl!.isNotEmpty;

    await _host.setTaskState(
      current.copyWith(
        clearError: true,
        clearStatusMessage: true,
        status: DownloadStatus.completed,
        fileSize: finalFileSize,
        downloadedBytes: (current.isTorrent || hasAudio) && finalFileSize > 0
            ? finalFileSize
            : current.downloadedBytes,
        speed: 0,
        eta: 0,
        chunks: List<double>.filled(current.threadCount, 1.0),
        completedAt: now,
        updatedAt: now,
        torrentFiles: current.torrentFiles != null
            ? _host.markTorrentFilesCompleted(current.torrentFiles!)
            : null,
      ),
    );

    if (_host.providerSettingsProvider.vibration) {
      HapticFeedback.vibrate();
    }

    XdmAnnouncer.announce('${current.fileName} download complete');

    final finalPath = p.join(current.savePath, current.fileName);
    if (Platform.isAndroid && finalPath.isNotEmpty) {
      if (current.isTorrent && Directory(finalPath).existsSync()) {
        // Multi-file torrent: finalPath is a directory — insert each file.
        final torrentDir = Directory(finalPath);
        try {
          await for (final entity in torrentDir.list(recursive: true)) {
            if (entity is! File) continue;
            final ext = p.extension(entity.path);
            if (ext == '.txt') continue;
            final mimeType = _mimeTypeFromExtension(ext);
            final mediaResult = await PermissionService().insertIntoMediaStore(
              p.basename(entity.path),
              mimeType,
              entity.path,
            );
            if (mediaResult == null) {
              try {
                unawaited(
                  _mediaChannel.invokeMethod('scanMedia', {'path': entity.path}),
                );
              } catch (e) {
                debugPrint('Failed to scan media: $e');
              }
            }
          }
        } catch (e) {
          debugPrint('Failed to list or scan torrent directory: $e');
        }
      } else if (current.isTorrent && !File(finalPath).existsSync()) {
        // Single-file torrent: guessed name differs from actual metadata name.
        // Scan savePath for the file libtorrent actually created.
        String actualFilePath = finalPath;
        String actualFileName = current.fileName;
        final saveDir = Directory(current.savePath);
        if (saveDir.existsSync()) {
          await for (final entity in saveDir.list(recursive: false)) {
            if (entity is File) {
              actualFilePath = entity.path;
              actualFileName = p.basename(entity.path);
              break;
            }
          }
        }
        final mimeType = _mimeTypeFromExtension(p.extension(actualFileName));
        final mediaResult = await PermissionService().insertIntoMediaStore(
          actualFileName,
          mimeType,
          actualFilePath,
        );
        if (mediaResult == null) {
          try {
            unawaited(
              _mediaChannel.invokeMethod('scanMedia', {'path': actualFilePath}),
            );
          } catch (e) {
            debugPrint('Failed to scan media: $e');
          }
        }
      } else {
        // HTTP download: original behavior.
        final mimeType = _mimeTypeFromExtension(p.extension(current.fileName));
        final mediaResult = await PermissionService().insertIntoMediaStore(
          current.fileName,
          mimeType,
          finalPath,
        );
        if (mediaResult == null) {
          try {
            unawaited(
              _mediaChannel.invokeMethod('scanMedia', {'path': finalPath}),
            );
          } catch (e) {
            debugPrint('Failed to scan media: $e');
          }
        }
      }
    }

    _host.notifications.showComplete(current, notificationId);
  }

  /// Execute the download retry loop with parallel video/audio downloads.
  Future<void> _executeDownload(
    DownloadTask task,
    int runtimeThreadCount,
    String cookieString,
    int notificationId,
    bool isAutoName,
    bool hasAudio,
    String? audioTempPath,
    bool isYoutube,
    int videoTransferSize,
    int? torrentId,
    CancelToken cancelToken,
  ) async {
    final streamThreadCount = runtimeThreadCount;
    final currentTask = _host.findTaskById(task.id);
    if (currentTask == null) return;
    task = currentTask;
    final maxRetries = _host.providerSettingsProvider.autoRetryEnabled
        ? _host.providerSettingsProvider.maxRetries
        : 0;
    int attempt = 0;

    // Track effective thread count and TTFB in metrics
    _host.downloadMetrics[task.id]?.effectiveThreads = runtimeThreadCount;
    int? ttfbTimestamp;

    final tempFile = File(task.tempFilePath);
    final audioFile = hasAudio && audioTempPath != null ? File(audioTempPath) : null;
    final tempLen = tempFile.existsSync() ? tempFile.lengthSync() : 0;
    final audioLen = audioFile != null && audioFile.existsSync() ? audioFile.lengthSync() : 0;

    int audioBytesSoFar = hasAudio && task.audioSize > 0
        ? (task.audioProgress >= 1.0
            ? task.audioSize
            : max((task.audioProgress * task.audioSize).round(), audioLen))
        : audioLen;
    int videoBytesSoFar = tempLen > 0
        ? tempLen
        : (task.downloadedBytes - audioBytesSoFar).clamp(
            0,
            task.fileSize > 0 ? task.fileSize : task.downloadedBytes,
          );
    double audioSpeedNow = 0.0;
    double videoSpeedNow = 0.0;
    int videoSizeSoFar = videoTransferSize;

    void pushCombinedProgress({
      List<double>? chunksOverride,
      bool? supportsResumeOverride,
      List<Map<String, dynamic>>? torrentFilesOverride,
      String? fileNameOverride,
      String? localFilePathOverride,
      String? tempFilePathOverride,
      String? categoryOverride,
      String? statusMessageOverride,
    }) {
      final index = _host.providerTasks.indexWhere((t) => t.id == task.id);
      if (index == -1) return;
      final base = _host.providerTasks[index];
      if (base.status != DownloadStatus.downloading) return;

      final audioContribution = hasAudio
          ? (base.audioSize > 0 ? base.audioSize : 0)
          : 0;
      final effectiveVideoSize = videoSizeSoFar > 0
          ? videoSizeSoFar
          : videoTransferSize;
      final totalSize = effectiveVideoSize + audioContribution;
      final totalDownloaded = audioBytesSoFar + videoBytesSoFar;
      final instantSpeed = audioSpeedNow + videoSpeedNow;
      final speedQueue = _host.speedHistories[task.id];
      if (speedQueue != null) {
        speedQueue.add(instantSpeed);
        if (speedQueue.length > 20) speedQueue.removeFirst();
      }
      final combinedSpeed = speedQueue != null && speedQueue.isNotEmpty
          ? speedQueue.reduce((a, b) => a + b) / speedQueue.length
          : instantSpeed;

      int? calculatedEta;
      if (combinedSpeed.isFinite &&
          combinedSpeed > 0 &&
          totalSize > totalDownloaded) {
        final remainingBytes = max(0, totalSize - totalDownloaded);
        final rawEta = (remainingBytes / combinedSpeed).round();
        if (rawEta > 0 && rawEta.isFinite) {
          final prevEta = base.eta;
          if (prevEta != null && prevEta > 0) {
            calculatedEta = ((0.3 * rawEta) + (0.7 * prevEta)).round();
          } else {
            calculatedEta = rawEta;
          }
        }
      }

      final updated = base.copyWith(
        fileName: fileNameOverride ?? base.fileName,
        localFilePath: localFilePathOverride ?? base.localFilePath,
        tempFilePath: tempFilePathOverride ?? base.tempFilePath,
        category: categoryOverride ?? base.category,
        fileSize: totalSize,
        downloadedBytes: totalDownloaded,
        speed: combinedSpeed,
        eta: calculatedEta,
        clearEta: calculatedEta == null,
        chunks: chunksOverride ?? base.chunks,
        supportsResume: supportsResumeOverride ?? base.supportsResume,
        torrentFiles: torrentFilesOverride ?? base.torrentFiles,
        statusMessage: statusMessageOverride,
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      final lastUpdate = _host.lastProgressUpdateTimes[task.id] ?? 0;
      if (now - lastUpdate >= 250) {
        _host.lastProgressUpdateTimes[task.id] = now;
        _host.providerTasks[index] = updated;
        _host.providerNotifyListeners();

        final progressPercent = totalSize > 0
            ? ((totalDownloaded / totalSize) * 100).round().clamp(0, 100)
            : 0;
        _host.notifications.showProgress(
          notificationId: notificationId,
          title: task.fileName,
          progressPercent: progressPercent,
          speed: updated.speedFormatted,
          eta: updated.etaFormatted,
          payload: _host.notifications.opaqueHandleFor(task.id),
        );
        unawaited(BackgroundService.sendHeartbeat());
      } else {
        _host.providerTasks[index] = updated;
        _host.pendingProgressUpdates.add(task.id);
      }
    }

    StreamSubscription? cancelSub;
    CancelToken? activeVideoCancelToken;
    CancelToken? activeAudioCancelToken;

    cancelSub = cancelToken.whenCancel
        .then((_) {
          final v = activeVideoCancelToken;
          final a = activeAudioCancelToken;
          if (v != null && !v.isCancelled) {
            v.cancel();
          }
          if (a != null && !a.isCancelled) {
            a.cancel();
          }
        })
        .asStream()
        .listen(null);

    try {
      while (true) {
        attempt++;

        final videoCancelToken = CancelToken();
        final audioCancelToken = CancelToken();
        activeVideoCancelToken = videoCancelToken;
        activeAudioCancelToken = audioCancelToken;

        try {
          Future<void> runAudio() async {
            final liveAudioTask = _host.findTaskById(task.id);
            if (liveAudioTask == null) return;
            final liveHasAudio =
                !liveAudioTask.isTorrent &&
                liveAudioTask.mergedAudioUrl != null &&
                liveAudioTask.mergedAudioUrl!.isNotEmpty;
            if (!liveHasAudio) return;
            final liveAudioTempPath = '${liveAudioTask.tempFilePath}.audio';
            final liveAudioSize = liveAudioTask.audioSize;

            final audioFile = File(liveAudioTempPath);
            final audioExists = await audioFile.exists();
            final audioLen = audioExists ? await audioFile.length() : 0;

            // Audio is considered complete ONLY when:
            // 1. audioProgress is at 1.0 (exact stream completion), OR
            // 2. audio exists on disk AND size is known AND downloaded bytes >= expected size.
            // The 0.99 heuristic is REMOVED because it can merge truncated audio.
            final isAudioComplete =
                liveAudioTask.audioProgress >= 1.0 ||
                (audioExists &&
                    audioLen > 0 &&
                    liveAudioSize > 0 &&
                    audioLen >= liveAudioSize);

            if (isAudioComplete) {
              debugPrint(
                '[DMX] Audio stream already complete ($audioLen bytes, progress: ${liveAudioTask.audioProgress}). Skipping audio re-download.',
              );
              audioBytesSoFar = liveAudioSize > 0 ? liveAudioSize : audioLen;
              audioSpeedNow = 0.0;
              final idx = _host.providerTasks.indexWhere(
                (x) => x.id == task.id,
              );
              if (idx != -1) {
                _host.providerTasks[idx] = _host.providerTasks[idx].copyWith(
                  audioProgress: 1.0,
                );
              }
              pushCombinedProgress();
              return;
            }

            debugPrint('[DMX] Parallel download: starting audio stream.');
            await _host.downloadEngine.download(
              url: liveAudioTask.mergedAudioUrl!,
              tempFilePath: liveAudioTempPath,
              localFilePath: liveAudioTempPath,
              knownFileSize: liveAudioSize,
              supportsResume: true,
              cancelToken: audioCancelToken,
              cookies: cookieString,
              oauthToken: YoutubeService.oauthToken,
              onProgress: (progress) {
                final t = _host.findTaskById(task.id);
                if (t == null || t.status != DownloadStatus.downloading) return;
                audioBytesSoFar = progress.downloadedBytes;
                audioSpeedNow = progress.speed;
                final size = t.audioSize > 0 ? t.audioSize : progress.fileSize;
                final fraction = size > 0
                    ? (progress.downloadedBytes / size).clamp(0.0, 1.0)
                    : 0.0;
                final idx = _host.providerTasks.indexWhere(
                  (x) => x.id == task.id,
                );
                if (idx != -1) {
                  _host.providerTasks[idx] = _host.providerTasks[idx].copyWith(
                    audioProgress: fraction,
                    audioSize: size,
                  );
                }
                pushCombinedProgress(
                  statusMessageOverride: progress.statusMessage,
                );
              },
              speedLimitBytesPerSecond: () {
                final current = _host.findTaskById(task.id);
                if (current != null && current.speedLimitKbps > 0) {
                  return (current.speedLimitKbps * 1024) ~/ 8;
                }
                return _host.effectiveSpeedLimit();
              },
              activeDownloadCount: () => _host.downloadingTasksCount,
              threadCount: streamThreadCount,
              customUserAgent: _host.providerSettingsProvider.customUserAgent,
              referer: isYoutube
                  ? (task.downloadPageUrl ?? 'https://www.youtube.com/')
                  : null,
              enableProxy: _host.providerSettingsProvider.enableProxy,
              proxyAddress: _host.providerSettingsProvider.proxyAddress,
              proxyHost: _host.providerSettingsProvider.proxyHost,
              proxyPort: _host.providerSettingsProvider.proxyPort,
              proxyUsername: _host.providerSettingsProvider.proxyUsername,
              proxyPassword: _host.providerSettingsProvider.proxyPassword,
              bypassSSL: _host.providerSettingsProvider.bypassSSL,
              isNameAutoGenerated: false,
            );

            if (!await audioFile.exists()) {
              throw Exception(
                'Audio file not found after download: $liveAudioTempPath',
              );
            }
            final downloadedAudioLen = await audioFile.length();
            debugPrint(
              '[DMX] Audio download complete: $audioTempPath ($downloadedAudioLen bytes)',
            );
            if (downloadedAudioLen == 0) {
              throw Exception('Audio file is empty: $audioTempPath');
            }
            audioBytesSoFar = task.audioSize > 0
                ? task.audioSize
                : downloadedAudioLen;
            audioSpeedNow = 0.0;
            final idx = _host.providerTasks.indexWhere((x) => x.id == task.id);
            if (idx != -1) {
              _host.providerTasks[idx] = _host.providerTasks[idx].copyWith(
                audioProgress: 1.0,
              );
            }
            pushCombinedProgress();
          }

          Future<void> runVideo() async {
            final liveVideoTask = _host.findTaskById(task.id);
            final liveHasAudio =
                liveVideoTask != null &&
                !liveVideoTask.isTorrent &&
                liveVideoTask.mergedAudioUrl != null &&
                liveVideoTask.mergedAudioUrl!.isNotEmpty;
            final liveVideoTransferSize =
                liveHasAudio &&
                    liveVideoTask.audioSize > 0 &&
                    liveVideoTask.fileSize > liveVideoTask.audioSize
                ? liveVideoTask.fileSize - liveVideoTask.audioSize
                : liveVideoTask?.fileSize ?? videoTransferSize;
            debugPrint('[DMX] Parallel download: starting video stream.');
            await _host.downloadEngine.download(
              url: task.url,
              tempFilePath: task.tempFilePath,
              localFilePath: task.localFilePath,
              knownFileSize: liveVideoTransferSize,
              supportsResume: task.supportsResume,
              cancelToken: videoCancelToken,
              isNameAutoGenerated: isAutoName,
              referer: isYoutube ? task.downloadPageUrl : null,
              getTorrentFiles: () =>
                  _host.findTaskById(task.id)?.torrentFiles ??
                  task.torrentFiles,
              torrentId: torrentId,
              cookies: cookieString,
              oauthToken: YoutubeService.oauthToken,
              onProgress: (progress) {
                // TTFB tracking: record ms until first byte
                if (ttfbTimestamp == null && progress.downloadedBytes > 0) {
                  ttfbTimestamp = DateTime.now().millisecondsSinceEpoch;
                  _host.downloadMetrics[task.id]?.timeToFirstByteMs =
                      ttfbTimestamp! - task.createdAt.millisecondsSinceEpoch;
                }
                final current = _host.findTaskById(task.id);
                if (current == null ||
                    current.status != DownloadStatus.downloading) {
                  return;
                }
                videoBytesSoFar = max(
                  videoBytesSoFar,
                  progress.downloadedBytes,
                );
                videoSpeedNow = progress.speed;
                if (progress.fileSize > 0) {
                  videoSizeSoFar = progress.fileSize;
                }

                if (isYoutube &&
                    progress.downloadedBytes > 1024 * 1024 &&
                    progress.speed > 0 &&
                    progress.speed < 120 * 1024) {
                  final lowSpeedCount =
                      (_host.ytLowSpeedCounts[task.id] ?? 0) + 1;
                  _host.ytLowSpeedCounts[task.id] = lowSpeedCount;
                  Logger.root.warning(
                    'Suspiciously low YouTube download speed (${(progress.speed / 1024).toStringAsFixed(1)} KB/s) for video ${task.id} (sample $lowSpeedCount). '
                    'The stream URL may be throttled due to n-parameter descrambling.',
                  );
                  if (lowSpeedCount >= 10 &&
                      !(_host.ytThrottlingRefreshing[task.id] ?? false)) {
                    _host.ytThrottlingRefreshing[task.id] = true;
                    _host.ytLowSpeedCounts[task.id] = 0;
                    Logger.root.info(
                      'Persistent YouTube throttling detected for ${task.id}. Attempting automatic stream refresh...',
                    );
                    Future.microtask(() async {
                      const maxRefreshAttempts = 3;
                      final attempts = (_ytRefreshAttempts[task.id] ?? 0) + 1;
                      _ytRefreshAttempts[task.id] = attempts;
                      try {
                        final pageUrl = task.downloadPageUrl ?? task.url;
                        final fresh = await YoutubeService.getFreshStreams(
                          pageUrl,
                        );
                        if (fresh != null && fresh['url'] != null) {
                          _ytRefreshAttempts.remove(task.id);
                          _host.ytLowSpeedCounts.remove(task.id);
                          await _host.updateTaskUrlAndResume(
                            task.id,
                            fresh['url']!,
                            newAudioUrl: fresh['audioUrl'],
                          );
                        } else if (attempts < maxRefreshAttempts) {
                          debugPrint(
                            '[DMX] YT refresh attempt $attempts returned null, will retry',
                          );
                        } else {
                          debugPrint(
                            '[DMX] YT refresh exhausted $maxRefreshAttempts attempts',
                          );
                          _ytRefreshAttempts.remove(task.id);
                        }
                      } catch (err) {
                        debugPrint(
                          '[DMX] YT refresh attempt $attempts failed: $err',
                        );
                        if (attempts >= maxRefreshAttempts) {
                          _ytRefreshAttempts.remove(task.id);
                        }
                      } finally {
                        _host.ytThrottlingRefreshing[task.id] = false;
                      }
                    });
                  }
                } else if (isYoutube && progress.speed >= 120 * 1024) {
                  _host.ytLowSpeedCounts[task.id] = 0;
                }

                final speedQueue = _host.speedHistories[task.id] ??=
                    Queue<double>();
                speedQueue.add(progress.speed);
                if (speedQueue.length > 20) speedQueue.removeFirst();

                final index = _host.providerTasks.indexWhere(
                  (t) => t.id == task.id,
                );
                if (index == -1) return;
                final base = _host.providerTasks[index];

                final newFileName = isAutoName && progress.fileName != null
                    ? progress.fileName!
                    : base.fileName;
                final newLocalPath = newFileName != base.fileName
                    ? p.join(
                        p.dirname(base.localFilePath),
                        safeFileName(newFileName),
                      )
                    : base.localFilePath;
                final newTempPath = newFileName != base.fileName
                    ? _host.downloadEngine.buildTempFilePath(
                        p.dirname(base.localFilePath),
                        newFileName,
                      )
                    : base.tempFilePath;
                final newCategory =
                    newFileName != base.fileName && base.category == 'Other'
                    ? categoryFromFileName(newFileName)
                    : base.category;

                List<Map<String, dynamic>>? diskVerifiedFiles;
                // Only use disk scan as initial seed data BEFORE the engine has
                // reported actual per-file progress. Once the engine reports real
                // per-file bytes, disk scans would overwrite accurate piece-level
                // accounting with imprecise file sizes (libtorrent writes pieces
                // that span multiple files).
                // FIX(4): Treat "has data" as "real bytes OR an explicit estimate" so disk scans don't clobber engine data
                final engineHasActualPerFileProgress =
                    progress.torrentFiles != null &&
                    progress.torrentFiles!.isNotEmpty &&
                    progress.torrentFiles!.any(
                      (f) =>
                          f['progressEstimated'] == false ||
                          ((f['downloadedBytes'] as int?) ?? 0) > 0,
                    );
                if (task.isTorrent &&
                    !engineHasActualPerFileProgress &&
                    progress.torrentFiles != null &&
                    progress.torrentFiles!.isNotEmpty) {
                  final nowMs = DateTime.now().millisecondsSinceEpoch;
                  if (nowMs - (_host.lastTorrentFileDiskSync[task.id] ?? 0) >=
                      4000) {
                    _host.lastTorrentFileDiskSync[task.id] = nowMs;
                    try {
                      final scan = _host.scanExistingTorrentData(
                        current.localFilePath,
                        progress.torrentFiles,
                      );
                      diskVerifiedFiles = scan.files;
                    } catch (e) {
                      debugPrint('[DMX] Disk-verify torrent files failed: $e');
                    }
                  }
                }

                pushCombinedProgress(
                  chunksOverride:
                      progress.chunks ??
                      _host.buildChunks(
                        streamThreadCount,
                        videoSizeSoFar > 0 ? videoSizeSoFar : videoTransferSize,
                        progress.downloadedBytes,
                      ),
                  supportsResumeOverride: progress.supportsResume,
                  torrentFilesOverride:
                      diskVerifiedFiles ?? progress.torrentFiles,
                  fileNameOverride: newFileName,
                  localFilePathOverride: newLocalPath,
                  tempFilePathOverride: newTempPath,
                  categoryOverride: newCategory,
                  statusMessageOverride: progress.statusMessage,
                );

                // When the torrent metadata name update changes localFilePath,
                // persist it to the database immediately so _finalizeDownload
                // can locate the file without relying on throttled saves.
                if (newLocalPath != base.localFilePath) {
                  unawaited(
                    _host.providerDatabaseService.saveTask(
                      _host.providerTasks[index],
                    ),
                  );
                }
              },
              speedLimitBytesPerSecond: () {
                final current = _host.findTaskById(task.id);
                if (current != null && current.speedLimitKbps > 0) {
                  return (current.speedLimitKbps * 1024) ~/ 8;
                }
                return _host.effectiveSpeedLimit();
              },
              activeDownloadCount: () => _host.downloadingTasksCount,
              threadCount: streamThreadCount,
              customUserAgent: _host.providerSettingsProvider.customUserAgent,
              enableProxy: _host.providerSettingsProvider.enableProxy,
              proxyAddress: _host.providerSettingsProvider.proxyAddress,
              proxyHost: _host.providerSettingsProvider.proxyHost,
              proxyPort: _host.providerSettingsProvider.proxyPort,
              proxyUsername: _host.providerSettingsProvider.proxyUsername,
              proxyPassword: _host.providerSettingsProvider.proxyPassword,
              bypassSSL: _host.providerSettingsProvider.bypassSSL,
            );
          }

          await Future.wait([runVideo(), runAudio()]);
          return;
        } catch (error) {
          if (!videoCancelToken.isCancelled) videoCancelToken.cancel();
          if (!audioCancelToken.isCancelled) audioCancelToken.cancel();

          final isYoutubeDownload =
              (task.downloadPageUrl != null &&
                  YoutubeService.extractVideoId(task.downloadPageUrl!) !=
                      null) ||
              task.url.contains('.googlevideo.com/') ||
              task.youtubeQualityPreset != null;
          bool shouldRefreshYoutube = false;
          if (isYoutubeDownload) {
            final errStr = error.toString();
            final statusCode = error is DioException
                ? error.response?.statusCode
                : null;
            if (statusCode == 403 ||
                statusCode == 410 ||
                errStr.contains('403') ||
                errStr.contains('410') ||
                errStr.contains('Forbidden')) {
              shouldRefreshYoutube = true;
            }
          }
          if (shouldRefreshYoutube) {
            final ytMaxRetries = maxRetries > 0 ? maxRetries : 3;
            if (attempt > ytMaxRetries) {
              rethrow;
            }
            try {
              YoutubeService.resetClient();
              final pageUrl =
                  (task.downloadPageUrl != null &&
                      task.downloadPageUrl!.isNotEmpty)
                  ? task.downloadPageUrl!
                  : task.url;
              Map<String, dynamic>? newUrlInfo;
              if (hasAudio) {
                final freshStreams = await YoutubeService.getFreshStreams(
                  pageUrl,
                );
                if (freshStreams != null && freshStreams['url'] != null) {
                  newUrlInfo = {
                    'url': freshStreams['url'],
                    'audioUrl': freshStreams['audioUrl'],
                  };
                }
              } else {
                newUrlInfo = await _refreshYoutubeStreamUrlSafe(
                  pageUrl,
                  task.url,
                );
              }
              if (newUrlInfo != null && newUrlInfo['url'] != null) {
                final refreshedUrl = newUrlInfo['url'] as String;
                final refreshedAudioUrl = newUrlInfo['audioUrl'] as String?;
                if (!youtubeMimeCompatible(task.url, refreshedUrl)) {
                  rethrow;
                }
                final idx = _host.providerTasks.indexWhere(
                  (x) => x.id == task.id,
                );
                if (idx != -1) {
                  _host.providerTasks[idx] = _host.providerTasks[idx].copyWith(
                    url: refreshedUrl,
                    mergedAudioUrl: refreshedAudioUrl ?? task.mergedAudioUrl,
                  );
                }
                await _host.providerDatabaseService.saveTask(
                  _host.providerTasks[idx],
                );
                rethrow;
              }
            } catch (e) {
              // ignore
            }
          }
          _ytRefreshAttempts.remove(task.id);
          rethrow;
        }
      }
    } finally {
      await cancelSub.cancel();
    }
  }

  Future<void> _startTaskBody(DownloadTask task) async {
    // Clean up stale torrent IDs for tasks that no longer exist
    _host.providerTorrentIds.removeWhere(
      (id, _) => !_host.providerTasks.any((t) => t.id == id),
    );

    // Apply global connection cap override from queue pump (runtime-only, never mutates stored task)
    final runtimeThreadCount =
        _host.effectiveThreadOverrides.remove(task.id) ?? task.threadCount;

    final hasWifiOrEthernet = _host.networkMonitor.hasWifiOrEthernet;
    if (_host.providerSettingsProvider.wifiOnly && !hasWifiOrEthernet) {
      await _host.setTaskState(
        task.copyWith(
          status: DownloadStatus.paused,
          errorMessage: DownloadStatusMessages.waitingWifi,
        ),
      );
      return;
    }

    if (_host.downloadingTasksCount == 0) {
      BackgroundService.start();
      // Prompt for battery optimization exemption once per app install
      if (!_host.providerSettingsProvider.batteryOptimizationPrompted) {
        _host.providerSettingsProvider.setBatteryOptimizationPrompted(true);
        PermissionService().requestBatteryOptimizationExemption();
      }
    }
    _host.notifications.updateBackgroundNotification();
    _host.providerStartWidgetTimer();
    _host.updateTelemetryWidget();

    final cookieString = await _resolveStreamUrl(task);
    if (cookieString == null) return;

    final cancelToken = CancelToken();
    _host.cancelTokens[task.id] = cancelToken;
    final earlyReturnCompleter = Completer<void>();
    _host.activeFutures[task.id] = earlyReturnCompleter.future;
    // Guard: if a concurrent cancel/pause fired during the async gap above,
    // the task status will no longer be 'queued'. Re-check the live status
    // Instead of using a stale cancellation gate,
    // we rely on cancel token removal to gate resumes.
    final latestBeforeStart = _host.findTaskById(task.id);
    if (latestBeforeStart == null ||
        latestBeforeStart.status != DownloadStatus.queued) {
      earlyReturnCompleter.complete();
      _host.activeFutures.remove(task.id);
      _host.cancelTokens.remove(task.id);
      return;
    }

    int? torrentId;
    if (task.isTorrent) {
      try {
        final existingTorrentId = _host.providerTorrentIds[task.id];
        if (existingTorrentId != null) {
          // Only reuse the handle if the native session still owns the
          // torrent. A magnet paused before metadata was fetched is REMOVED
          // from the session by the cancel handler, and `getFiles()` never
          // throws for a dead handle — it returns [] — so the old code
          // silently reused a dead id and resume hung until the 45s
          // metadata timeout, then failed.
          if (_isTorrentAlive(existingTorrentId)) {
            torrentId = existingTorrentId;
            // Wake the session early so torrentUpdates starts emitting while
            // the engine waits for metadata; a paused torrent can otherwise
            // stay silent and stall the metadata wait.
            TorrentService.resumeTorrent(existingTorrentId);
          } else {
            _host.providerTorrentIds.remove(task.id);
          }
        }
        if (torrentId == null) {
          final saveDir = task.savePath;
          if (task.url.startsWith('magnet:')) {
            torrentId = TorrentService.addMagnet(task.url, saveDir);
          } else {
            String filePath = task.url;
            if (task.url.startsWith('file://')) {
              filePath = Uri.parse(task.url).toFilePath();
            }
            torrentId = TorrentService.addTorrentFile(filePath, saveDir);
          }
          if (torrentId < 0) {
            throw Exception('Torrent engine rejected the torrent.');
          }
          _host.providerTorrentIds[task.id] = torrentId;
        }
      } catch (e) {
        _host.cancelTokens.remove(task.id);
        _host.activeFutures.remove(task.id);
        await _host.setTaskState(
          task.copyWith(
            status: DownloadStatus.failed,
            errorMessage: 'Failed to initialize torrent: $e',
          ),
        );
        _host.pumpQueue();
        _host.updateTelemetryWidget();
        return;
      }
    }

    // Fire-and-await so the queued→downloading transition is committed
    // before the first progress callback fires.
    // For torrents: update the file metadata list, but do NOT use the disk
    // scan to set downloadedBytes — libtorrent pre-allocates files to their
    // full size, so file.lengthSync() would falsely report 100% completion.
    final List<Map<String, dynamic>>? verifiedTorrentFiles = task.torrentFiles;
    final int realTotalDownloaded = task.downloadedBytes;
    // FIX(3): Do NOT re-derive per-file bytes from disk on resume: libtorrent
    // pre-allocates files to full length, so File.lengthSync() reports the full
    // size even for undownloaded files and would render every file as 100%.
    // Keep the engine's last-known per-file bytes; the engine re-reports
    // accurate values after the post-resume recheck.

    await _host.setTaskState(
      task.copyWith(
        status: DownloadStatus.downloading,
        downloadedBytes: realTotalDownloaded,
        clearError: true,
        clearStatusMessage: true,
        clearCompletedAt: true,
        torrentFiles: verifiedTorrentFiles,
      ),
    );

    // Wire DownloadMetrics for this task
    _host.downloadMetrics[task
        .id] = DownloadMetrics(taskId: task.id, url: task.url)
      ..requestedThreads = runtimeThreadCount
      ..resumed = realTotalDownloaded > 0
      ..resumeBytesSaved = realTotalDownloaded > 0 ? realTotalDownloaded : 0;

    final notificationId = _host.notifications.idFor(task.id);
    // Torrents always reconcile: the guessed name (magnet `dn`) may differ from
    // the real torrent name reported after metadata, and the task's paths must
    // point at the folder libtorrent actually uses so resume stays consistent.
    final isAutoName =
        task.isTorrent ||
        task.fileName == 'torrent_download.zip' ||
        task.fileName.isEmpty ||
        task.fileName == fileNameFromUrl(task.url) ||
        task.fileName.startsWith('download_');

    final hasAudio =
        !task.isTorrent &&
        task.mergedAudioUrl != null &&
        task.mergedAudioUrl!.isNotEmpty;
    final audioTempPath = hasAudio ? '${task.tempFilePath}.audio' : null;

    // Detect YouTube early so we can skip CDN HEAD probes that trigger 429s.
    final isYoutube =
        task.downloadPageUrl != null &&
        (task.downloadPageUrl!.contains('youtube.com/') ||
            task.downloadPageUrl!.contains('youtu.be/'));

    // Ensure audioSize is properly set for combined downloads.
    // Skip for YouTube — googlevideo.com CDN URLs 429 on extra HEAD requests
    // and the audio size is already provided by the stream resolution step.
    if (hasAudio &&
        task.audioSize <= 0 &&
        task.mergedAudioUrl != null &&
        !isYoutube) {
      try {
        final meta = await _host.downloadEngine.resolveMetadata(
          url: task.mergedAudioUrl!,
          customUserAgent: _host.providerSettingsProvider.customUserAgent,
          enableProxy: _host.providerSettingsProvider.enableProxy,
          proxyAddress: _host.providerSettingsProvider.proxyAddress,
          proxyHost: _host.providerSettingsProvider.proxyHost,
          proxyPort: _host.providerSettingsProvider.proxyPort,
          bypassSSL: _host.providerSettingsProvider.bypassSSL,
          cookies: cookieString,
          oauthToken: YoutubeService.oauthToken,
        );
        if (meta.fileSize > 0) {
          final idx = _host.providerTasks.indexWhere((t) => t.id == task.id);
          if (idx != -1) {
            _host.providerTasks[idx] = _host.providerTasks[idx].copyWith(
              audioSize: meta.fileSize,
            );
            task = _host.providerTasks[idx];
          }
        }
      } catch (e) {
        debugPrint('[DMX] Failed to resolve audio size: $e');
      }
    }

    // Recalculate video transfer size with correct audio size.
    // When sizes were set from stream info: videoTransferSize = fileSize - audioSize.
    // When only total fileSize is known (no sub-sizes from backend): use fileSize directly
    // and rely on the engine's own probe to determine actual video segment size.
    int videoTransferSize;
    if (hasAudio && task.audioSize > 0 && task.fileSize > task.audioSize) {
      videoTransferSize = task.fileSize - task.audioSize;
    } else if (hasAudio && task.audioSize > 0 && task.fileSize > 0) {
      // fileSize may only represent the video portion (backend returned total=videoSize)
      // or total is equal to audioSize — treat fileSize as total and subtract audio.
      videoTransferSize = (task.fileSize - task.audioSize).clamp(
        0,
        task.fileSize,
      );
    } else {
      videoTransferSize = task.fileSize;
    }

    // If the video transfer size is still unknown and this is NOT a YouTube
    // download, probe the video URL via HEAD so the engine can activate
    // multi-threaded mode. We skip this for YouTube because googlevideo.com
    // CDN URLs 429 easily and every extra HEAD wastes a signed URL's limited
    // window — the engine's single-thread fallback handles them fine.
    if (hasAudio && videoTransferSize <= 0 && !isYoutube) {
      try {
        final videoMeta = await _host.downloadEngine.resolveMetadata(
          url: task.url,
          customUserAgent: _host.providerSettingsProvider.customUserAgent,
          enableProxy: _host.providerSettingsProvider.enableProxy,
          proxyAddress: _host.providerSettingsProvider.proxyAddress,
          proxyHost: _host.providerSettingsProvider.proxyHost,
          proxyPort: _host.providerSettingsProvider.proxyPort,
          bypassSSL: _host.providerSettingsProvider.bypassSSL,
          cookies: cookieString,
          oauthToken: YoutubeService.oauthToken,
        );
        if (videoMeta.fileSize > 0) {
          videoTransferSize = videoMeta.fileSize;
          debugPrint(
            '[DMX] Resolved video transfer size via HEAD probe: $videoTransferSize bytes',
          );
        }
      } catch (e) {
        debugPrint('[DMX] Failed to resolve video transfer size: $e');
      }
    }

    if (videoTransferSize <= 0 && hasAudio && task.fileSize > 0) {
      videoTransferSize = 1;
      debugPrint(
        '[DMX] videoTransferSize was 0 (fileSize=${task.fileSize}, '
        'audioSize=${task.audioSize}); floored to 1',
      );
    }

    // YouTube streams use multi-threaded mode as configured.

    // Run video and audio in PARALLEL — each gets the full configured
    // thread count (streamThreadCount), not split between them.
    final downloadFuture =
        _executeDownload(
              task,
              runtimeThreadCount,
              cookieString,
              notificationId,
              isAutoName,
              hasAudio,
              audioTempPath,
              isYoutube,
              videoTransferSize,
              torrentId,
              cancelToken,
            )
            .then((_) async {
              if (hasAudio) {
                await _mergeAudioVideo(task.id, audioTempPath!);
              }
              await _finalizeDownload(task.id, notificationId);
            })
            .catchError((Object error, StackTrace stackTrace) async {
              final realError = error;

              debugPrint('================= DOWNLOAD ERROR =================');
              debugPrint('Task ID: ${task.id}');
              debugPrint('URL: ${task.url}');
              debugPrint('Error: $realError');
              if (realError is DioException) {
                debugPrint('DioException Type: ${realError.type}');
                debugPrint('DioException Message: ${realError.message}');
                debugPrint(
                  'DioException Response: ${realError.response?.data}',
                );
                debugPrint(
                  'DioException Status: ${realError.response?.statusCode}',
                );
              }
              debugPrint('Stacktrace: $stackTrace');
              debugPrint('==================================================');

              await _host.flushPendingProgress(task.id);
              final current = _host.findTaskById(task.id);
              if (current == null) return;

              if (realError is DioException &&
                  realError.type == DioExceptionType.cancel) {
                _host.retryCounts.remove(task.id);
                if (current.status == DownloadStatus.downloading) {
                  await _host.setTaskState(
                    current.copyWith(speed: 0, clearEta: true),
                  );
                }
                _host.notifications.cancelNotification(notificationId);
                return;
              }

              // Clean up transient audio sidecar files on failure if present, while preserving main partial file for resume
              try {
                if (hasAudio && audioTempPath != null) {
                  final audioFile = File(audioTempPath);
                  if (await audioFile.exists()) await audioFile.delete();
                }
              } catch (_) {}

              final isRetryable = isRetryableError(realError);
              final maxRetries =
                  _host.providerSettingsProvider.autoRetryEnabled && isRetryable
                  ? _host.providerSettingsProvider.maxRetries
                  : 0;
              final currentRetry = _host.retryCounts[task.id] ?? 0;

              if (currentRetry < maxRetries) {
                _host.retryCounts[task.id] = currentRetry + 1;
                final delaySeconds =
                    _host.providerSettingsProvider.retryDelaySeconds;
                debugPrint(
                  'Transient error for task ${task.id}. Retrying (${currentRetry + 1}/$maxRetries) in $delaySeconds seconds...',
                );

                await _host.setTaskState(
                  current.copyWith(
                    status: DownloadStatus.queued,
                    speed: 0,
                    errorMessage:
                        'Retrying in $delaySeconds seconds: ${errorMessage(realError)}',
                  ),
                );

                _host.retryTimers[task.id]?.cancel();
                _host.retryTimers[task.id] = Timer(
                  Duration(seconds: delaySeconds),
                  () {
                    _host.retryTimers.remove(task.id);
                    if (_host.providerDisposed) return;
                    final checkedTask = _host.findTaskById(task.id);
                    if (checkedTask != null &&
                        checkedTask.status == DownloadStatus.queued) {
                      _host.pumpQueue();
                    }
                  },
                );
                return;
              }

              _host.retryCounts.remove(task.id);
              _recordDownloadFailure(task.id, realError);
              try {
                await _host.cleanupPartFiles(current);
              } catch (e) {
                debugPrint('Failed to clean up temp files on non-retryable error: $e');
              }
              await _host.setTaskState(
                current.copyWith(
                  status: DownloadStatus.failed,
                  speed: 0,
                  clearEta: true,
                  clearStatusMessage: true,
                  errorMessage: errorMessage(realError),
                ),
              );
              _host.notifications.showFailed(
                notificationId: notificationId,
                title: task.fileName,
                error: errorMessage(realError),
              );
            })
            .whenComplete(() {
              _host.cancelTokens.remove(task.id);
              _host.activeFutures.remove(task.id);
              // Don't pumpQueue here if this task was set to queued (retry
              // scheduled by catchError). The retry timer will restart it after
              // the configured delay — immediate pumpQueue would defeat the delay
              // and create a fast fail loop.
              final status = _host.findTaskById(task.id)?.status;
              if (status != DownloadStatus.queued) {
                _host.pumpQueue();
              }
              if (_host.activeOrSeedingCount == 0) {
                BackgroundService.stop();
                _host.providerStopWidgetTimer();
              } else {
                _host.notifications.updateBackgroundNotification();
              }
              _host.updateTelemetryWidget();
            });
    earlyReturnCompleter.complete();
    _host.activeFutures[task.id] = downloadFuture;
  }

  /// A torrent handle is reusable only while the native session still owns
  /// it. Stats map first (cheap), then a live file query as fallback.
  bool _isTorrentAlive(int id) {
    if (_host.providerLatestTorrentStats.containsKey(id)) return true;
    try {
      return TorrentService.isTorrentAlive(id);
    } catch (_) {
      return false;
    }
  }

  // FIX #4: Prevent YouTube refresh from swapping video/audio MIME type.
  /// Whether the MIME types of old and new YouTube stream URLs are compatible.
  @visibleForTesting
  bool youtubeMimeCompatible(String oldUrl, String newUrl) {
    final oldMime = Uri.tryParse(
      oldUrl,
    )?.queryParameters['mime']?.split('/').first;
    final newMime = Uri.tryParse(
      newUrl,
    )?.queryParameters['mime']?.split('/').first;
    if (oldMime == null || newMime == null) return true;
    return oldMime == newMime;
  }

  Future<Map<String, dynamic>?> _refreshYoutubeStreamUrlSafe(
    String pageUrl,
    String oldStreamUrl,
  ) async {
    final refreshed = await YoutubeService.refreshStreamUrl(
      pageUrl,
      oldStreamUrl,
    );
    if (refreshed == null || refreshed.isEmpty) return refreshed;

    final refreshedUrl = refreshed['url'] as String?;
    if (refreshedUrl != null &&
        !youtubeMimeCompatible(oldStreamUrl, refreshedUrl)) {
      throw Exception(
        'YouTube stream type changed during URL refresh. Please re-add the download.',
      );
    }

    return refreshed;
  }

  /// Returns a user-friendly error message for the given [error].
  @visibleForTesting
  String errorMessage(Object error) {
    if (error is DownloadIntegrityException) {
      return 'Download integrity check failed: ${error.message}';
    }
    if (error is IsolateSpawnTimeoutException) {
      return error.message;
    }
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode != null) {
        return switch (statusCode) {
          403 => '403 Forbidden: Access denied. (Raw: ${error.message})',
          401 =>
            '401 Unauthorized: Authentication is required. (Raw: ${error.message})',
          404 =>
            '404 Not Found: The file was not found. (Raw: ${error.message})',
          410 =>
            '410 Gone: The file has been permanently removed. (Raw: ${error.message})',
          416 =>
            '416 Range Not Satisfiable: Invalid byte range. (Raw: ${error.message})',
          500 => '500 Internal Server Error. (Raw: ${error.message})',
          503 =>
            '503 Service Unavailable: Server is overloaded. (Raw: ${error.message})',
          _ =>
            'HTTP Error $statusCode: ${error.message ?? "Server returned invalid response."}',
        };
      }
      return 'Dio Error: ${error.message ?? error.type.name}';
    }
    return 'Error: ${error.toString()}';
  }

  /// Whether [error] is transient and the download should be retried.
  @visibleForTesting
  bool isRetryableError(Object error) {
    final msg = error.toString().toLowerCase();
    if (error is DownloadIntegrityException) {
      return false;
    }
    if (msg.contains('merge') ||
        msg.contains('ffmpeg') ||
        msg.contains('missing') ||
        msg.contains('not found')) {
      return false;
    }
    if (error is DioException) {
      if (error.type == DioExceptionType.cancel) {
        return false;
      }
      final statusCode = error.response?.statusCode;
      if (statusCode != null) {
        // Do not retry client errors (400 Bad Request, 401 Unauthorized, 403 Forbidden, 404 Not Found, 410 Gone, 416 Range Not Satisfiable)
        if (statusCode == 400 ||
            statusCode == 401 ||
            statusCode == 403 ||
            statusCode == 404 ||
            statusCode == 410 ||
            statusCode == 416) {
          return false;
        }
      }
    }
    return true;
  }

  /// Evicts stale cookies from the cache.
  @visibleForTesting
  void evictStaleCookies() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    _cookieCache.removeWhere((_, entry) => entry.timestamp.isBefore(cutoff));
    if (_cookieCache.length >= _cookieCacheMaxSize) {
      final oldest = _cookieCache.entries
          .reduce(
            (a, b) => a.value.timestamp.isBefore(b.value.timestamp) ? a : b,
          )
          .key;
      _cookieCache.remove(oldest);
    }
  }

  /// Maps common file extensions to MIME types for MediaStore insertion.
  static String _mimeTypeFromExtension(String ext) {
    switch (ext.toLowerCase()) {
      case '.mp4':
        return 'video/mp4';
      case '.mkv':
        return 'video/x-matroska';
      case '.webm':
        return 'video/webm';
      case '.avi':
        return 'video/x-msvideo';
      case '.mov':
        return 'video/quicktime';
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
        return 'audio/mp4';
      case '.ogg':
      case '.opus':
        return 'audio/ogg';
      case '.wav':
        return 'audio/wav';
      case '.flac':
        return 'audio/flac';
      case '.pdf':
        return 'application/pdf';
      case '.zip':
        return 'application/zip';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.doc':
        return 'application/msword';
      case '.docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case '.apk':
        return 'application/vnd.android.package-archive';
      default:
        return 'application/octet-stream';
    }
  }

  void dispose() {
    _cookieCache.clear();
    _ytRefreshAttempts.clear();
    _startingTaskIds.clear();
  }
}
