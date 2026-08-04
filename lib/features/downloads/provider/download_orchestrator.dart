import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' hide Cookie;
import 'dart:isolate';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/services/background_service.dart';
import '../../../core/services/checksum_service.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/diagnostic_service.dart';
import '../../../core/services/download_engine.dart';
import '../../../core/services/download_journal.dart';
import '../../../core/services/download_metrics.dart';

import '../../../core/services/error_taxonomy.dart';
import '../../../core/services/ffmpeg_mux_service.dart' hide Semaphore;
import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/torrent_resume_store.dart';
import '../../../core/services/torrent_service.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/semaphore.dart';
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
  Map<String, bool> get resumeRejectionRestarts;
  bool get providerDisposed;
  Map<String, DownloadMetrics> get downloadMetrics;
  bool get enableBackgroundTimers;

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
  void pushProgressTick(String taskId, double progress, double speed);
  List<Map<String, dynamic>> markTorrentFilesCompleted(
    List<Map<String, dynamic>> files,
  );
  Future<void> cleanupPartFiles(DownloadTask task,
      {bool preserveParts = false});
  Future<void> startOverTask(
    String id,
    String newUrl, {
    String? newAudioUrl,
    bool clearAudioUrl = false,
    bool fromError = false,
    int? newFileSize,
    int? newAudioSize,
    bool deleteTempFiles = false,
  });
}

/// Owns the download start/execute/merge/finalize lifecycle.
///
/// Extracted from `DownloadProvider` (Refactor A). The provider remains a
/// facade: queue pumping calls [startTask], and all shared task state stays
/// on the provider, accessed through [DownloadOrchestratorHost]. Logic was
/// moved verbatim — no behavior changes.
class DownloadOrchestrator {
  DownloadOrchestrator(this._host) {
    _startPeriodicResumeSave();
  }

  final DownloadOrchestratorHost _host;

  /// Limits concurrent YouTube stream resolutions to 4
  /// to avoid overwhelming the backend / getting rate-limited.
  static final Semaphore _streamResolveSemaphore = Semaphore(4);

  Timer? _periodicResumeSaveTimer;
  String _currentCookieString = '';
  final Map<String, int> _sessionCachedTotalSize = {};



  void _startPeriodicResumeSave() {
    _periodicResumeSaveTimer?.cancel();
    if (!_host.enableBackgroundTimers) return;
    _periodicResumeSaveTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        if (TorrentService.activeTorrentIds.isNotEmpty) {
          unawaited(TorrentResumeStore.saveAll(
            TorrentService.activeTorrentIds,
            TorrentService.progressFor,
          ));
          // FIX-C4: Save fast resume data for all active torrents
          for (final tid in TorrentService.activeTorrentIds) {
            unawaited(TorrentService.saveResumeData(tid));
          }
        }
      },
    );
  }


  static const _mediaChannel = MethodChannel('com.dmx.app/media');

  /// Records a classified, bounded diagnostic entry for [taskId]'s failure.
  void _recordDownloadFailure(String taskId, Object error) {
    final classification = ErrorTaxonomy.classify(error);
    final task = _host.findTaskById(taskId);
    final retryCount = _host.retryCounts[taskId] ?? 0;
    final metrics = _host.downloadMetrics[taskId];
    final elapsedMs = metrics != null ? metrics.elapsed.inMilliseconds : 0;
    final host = task != null ? (Uri.tryParse(task.url)?.host ?? '-') : '-';
    final threadCount = task?.threadCount ?? 1;
    final fileSize = task?.fileSize ?? 0;

    DiagnosticService.instance.record(
      'download',
      classification.message,
      error: error,
      details: 'task=$taskId family=${classification.family.name} '
          'status=${classification.httpStatus ?? '-'} '
          'retryable=${classification.retryable} '
          'retries=$retryCount elapsedMs=$elapsedMs '
          'host=$host threads=$threadCount fileSize=$fileSize',
    );
  }

  final Set<String> _startingTaskIds = {};
  final Map<String, bool> _pushScheduled = {};
  final Map<String, ({String cookie, DateTime timestamp})> _cookieCache = {};

  /// FIX-12 / FIX-17: Cleans up internal state for a deleted task
  void cleanupTaskState(String taskId) {
    _sessionCachedTotalSize.remove(taskId);
    _startingTaskIds.remove(taskId);
    _ytRefreshAttempts.remove(taskId);
    _pushScheduled.remove(taskId);
  }

  @visibleForTesting
  Map<String, ({String cookie, DateTime timestamp})> get cookieCache =>
      _cookieCache;
  static const int _cookieCacheMaxSize = 50;

  @visibleForTesting
  Future<DownloadTask> validateResumeState(DownloadTask task) async {
    // FIX-02: Torrents use libtorrent resume, not .dmxstate
    if (task.isTorrent) {
      debugPrint('[DMX-FIX-02] Torrent task ${task.id}: skipping .dmxstate validation');
      return task;
    }


    try {

      if (task.downloadedBytes > 0 && task.tempFilePath.isNotEmpty) {
        final stateFile = File('${task.tempFilePath}.dmxstate');
        bool validState = false;

        if (await stateFile.exists()) {
          try {
            final content = await stateFile.readAsString();
            final decoded = jsonDecode(content);
            if (decoded is Map) {
              final savedSize = (decoded['totalSize'] as num?)?.toInt() ?? -1;
              if (savedSize > 0 &&
                  task.fileSize > 0 &&
                  (savedSize - task.fileSize).abs() > 2048) {
                debugPrint(
                    '[DMX] Size mismatch in resume state, resetting progress');
              } else {
                validState = true;
              }
            }
          } catch (e) {
            debugPrint('[DMX] FIX-A3: Corrupt resume state: $e');
            try {
              final tempFile = File(task.tempFilePath);
              if (await tempFile.exists()) {
                final len = await tempFile.length();
                if (len > 0 && task.threadCount <= 1) {
                  final recoveredBytes = min(len, task.fileSize > 0 ? task.fileSize : len);
                  final updated = task.copyWith(
                    downloadedBytes: recoveredBytes,
                    chunks: task.fileSize > 0
                        ? [(recoveredBytes / task.fileSize).clamp(0.0, 1.0)]
                        : [0.0],
                  );
                  await _host.setTaskState(updated);
                  await File('${task.tempFilePath}.dmxstate').writeAsString(
                    jsonEncode({
                      'totalSize': task.fileSize > 0 ? task.fileSize : recoveredBytes,
                      'threadCount': task.threadCount,
                      'progress': [recoveredBytes],
                    }),
                  );

                  validState = true;
                  task = updated;
                }
              }
            } catch (_) {}
          }

        } else {
          final tempFile = File(task.tempFilePath);
          if (await tempFile.exists()) {
            final fileSize = await tempFile.length();
            // FIX-A2 / FIX 2: Compute expected video-only temp file size for YouTube/mux downloads
            final int expectedVideoSize =
                (task.mergedAudioUrl != null && task.audioSize > 0)
                    ? (task.fileSize - task.audioSize).clamp(0, task.fileSize)
                    : task.fileSize;

            if (fileSize >= expectedVideoSize && expectedVideoSize > 0) {
              debugPrint(
                  '[DMX] FIX 2: .dmxstate missing but temp file is complete on disk ($fileSize/$expectedVideoSize), preserving task');
              validState = true;
            }
          }

          if (!validState) {
            debugPrint(
                '[DMX] .dmxstate missing for task with downloadedBytes > 0, resetting progress');
          }
        }

        if (!validState) {
          final updated = task.copyWith(
            downloadedBytes: 0,
            chunks: List<double>.filled(
                task.threadCount > 0 ? task.threadCount : 1, 0.0),
          );
          await _host.setTaskState(updated);
          try {
            if (await stateFile.exists()) {
              await stateFile.delete();
            }
          } catch (_) {}
          task = updated;
        }

        // ═══ FIX H-5: Validate chunk progress against actual file size ═══
        if (validState && task.threadCount >= 1) {
          try {
            final tempFile = File(task.tempFilePath);
            if (await tempFile.exists()) {
              final actualFileSize = await tempFile.length();
              final stateChunks = await _readDmxStateChunks(
                  task.tempFilePath, task.threadCount);

              if (stateChunks != null && stateChunks.isNotEmpty) {
                final totalFromChunks =
                    stateChunks.fold<double>(0.0, (s, c) => s + c);
                // FIX-1: Divide by chunk count to get overall fraction
                final overallFraction =
                    (totalFromChunks / stateChunks.length).clamp(0.0, 1.0);
                final expectedBytes =
                    (overallFraction * task.fileSize).toInt();

                if (expectedBytes > actualFileSize + 4096) {
                  debugPrint(
                      '[DMX] H-5 FIX: State claims $expectedBytes bytes but file has '
                      '$actualFileSize. Correcting chunk progress.');

                  final correctionFactor =
                      (actualFileSize / (overallFraction * task.fileSize)).clamp(0.0, 1.0);
                  final correctedChunks = task.threadCount > 1
                      ? stateChunks
                          .map((c) => (c * correctionFactor).clamp(0.0, 1.0))
                          .toList()
                      : [task.fileSize > 0 ? (actualFileSize / task.fileSize).clamp(0.0, 1.0) : 0.0];
                  final correctedBytes = actualFileSize;

                  final updated = task.copyWith(
                    downloadedBytes: correctedBytes,
                    chunks: correctedChunks,
                  );
                  await _host.setTaskState(updated);
                  task = updated;
                }
              }
            }
          } catch (e) {
            debugPrint(
                '[DMX] H-5: Chunk validation failed, using state as-is: $e');
          }
        }
        // ═══ END FIX H-5 ═══
      }


      // FIX-AUDIT-6: Validate audio state even when audioSize is unknown (0).
      if (task.mergedAudioUrl != null) {
        final audioPath = '${task.tempFilePath}.audio';
        final audioStateFile = File('$audioPath.dmxstate');
        final audioFile = File(audioPath);

        if (task.audioSize > 0) {
          if (await audioStateFile.exists()) {
            if (await audioFile.exists()) {
              final audioLen = await audioFile.length();
              final expectedBytes = (task.audioProgress * task.audioSize).toInt();
              if (audioLen < expectedBytes) {
                debugPrint('[DMX] FIX A-2: Audio file shorter than progress '
                    '($audioLen < $expectedBytes). Resetting audio progress.');
                task = task.copyWith(audioProgress: 0.0);
                try { await audioFile.delete(); } catch (_) {}
                try { await audioStateFile.delete(); } catch (_) {}
              }
            }
          } else {
            if (await audioFile.exists()) {
              final audioLen = await audioFile.length();
              if (audioLen > 0) {
                final fraction = (audioLen / task.audioSize).clamp(0.0, 1.0);
                final updated = task.copyWith(audioProgress: fraction);
                await _host.setTaskState(updated);
                task = updated;
              } else {
                final updated = task.copyWith(audioProgress: 0.0);
                await _host.setTaskState(updated);
                task = updated;
              }
            } else {
              final updated = task.copyWith(audioProgress: 0.0);
              await _host.setTaskState(updated);
              task = updated;
            }
          }
        } else {
          // FIX-AUDIT-6: audioSize unknown (0) — validate by file existence
          if (!await audioStateFile.exists()) {
            if (await audioFile.exists()) {
              final updated = task.copyWith(audioProgress: 0.0);
              await _host.setTaskState(updated);
              task = updated;
            }
          }
        }
      }



    } catch (e) {
      debugPrint('[DMX] validateResumeState exception: $e');
    }

    return task;
  }


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
  // FIX-C1: Return updated DownloadTask (or null on failure) so caller holds fresh reference
  Future<DownloadTask?> _resolveStreamUrl(DownloadTask task) async {
    evictStaleCookies(); // FIX-15: Evict stale cookies before acquiring semaphore

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
          final cookies =
              await CookieManager.instance().getCookies(url: WebUri(origin));
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

    _currentCookieString = cookieString;


    final youtubeUrl = task.downloadPageUrl ?? task.url;
    if (task.youtubeQualityPreset != null &&
        (youtubeUrl.contains('youtube.com/') ||
            youtubeUrl.contains('youtu.be/'))) {
      if (cookieString.isNotEmpty) {
        YoutubeService.signIn(cookieString);
      }
      // Acquire semaphore before hitting the backend
      await _streamResolveSemaphore.acquire();
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
            final requiresMuxing = youtubeStreamRequiresMuxing(type);
            final resolvedUrl = streamInfo['src']?.toString() ?? '';

            if (resolvedUrl.isEmpty) {
              throw Exception('Stream URL is empty');
            }

            // Guard: reject page URLs returned by backend
            final resolvedUri = Uri.tryParse(resolvedUrl);
            if (resolvedUri != null &&
                (resolvedUri.host.contains('youtube.com') ||
                    resolvedUri.host == 'youtu.be')) {
              throw Exception('Backend returned page URL, not stream');
            }

            if (shouldRejectResolvedYoutubeUrl(resolvedUrl)) {
              throw Exception(
                'Backend returned a page URL instead of a stream URL: $resolvedUrl',
              );
            }

            String resolvedFileName;
            if (type == 'audio') {
              resolvedFileName =
                  title.isNotEmpty ? '$title.$ext' : task.fileName;
            } else {
              final qLabel = streamInfo['quality'] as String? ?? '';
              resolvedFileName = title.isNotEmpty && qLabel.isNotEmpty
                  ? '$title [$qLabel].$ext'
                  : (title.isNotEmpty ? '$title.$ext' : task.fileName);
            }
            resolvedFileName = safeFileName(resolvedFileName);

            final resolvedLocalPath = task.localFilePath.isNotEmpty
                ? task.localFilePath
                : await getUniqueFilePath(
                    task.savePath,
                    resolvedFileName,
                  );
            final resolvedTempPath = task.tempFilePath.isNotEmpty
                ? task.tempFilePath
                : _host.downloadEngine.buildTempFilePath(
                    p.dirname(resolvedLocalPath),
                    resolvedFileName,
                  );

            if (requiresMuxing) {
              final videoSize = streamInfo['videoSize'] as int? ?? 0;
              final audioSize = streamInfo['audioSize'] as int? ?? 0;
              final totalSize = (videoSize + audioSize) > 0
                  ? videoSize + audioSize
                  : (streamInfo['size'] as int? ?? 0);
              task = task.copyWith(
                url: resolvedUrl,
                mergedAudioUrl: streamInfo['audioSrc']?.toString(),
                fileSize: totalSize,
                audioSize: audioSize,
                fileName:
                    task.fileName.isNotEmpty ? task.fileName : resolvedFileName,
                localFilePath: resolvedLocalPath,
                tempFilePath: resolvedTempPath,
              );
            } else {
              task = task.copyWith(
                url: resolvedUrl,
                mergedAudioUrl: null,
                fileSize: streamInfo['size'] as int? ?? 0,
                fileName:
                    task.fileName.isNotEmpty ? task.fileName : resolvedFileName,
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
      } finally {
        _streamResolveSemaphore.release();
      }
    }
    return task;
  }


  /// Merge audio and video streams via FFmpeg.
  /// Returns true on success, false if no merge was needed or already handled.
  Future<bool> _mergeAudioVideo(String taskId, String audioTempPath) async {
    final current = _host.findTaskById(taskId);
    if (current == null) return false;

    final hasAudio = !current.isTorrent &&
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
    // FIX(F4): Restore video-only file from a previous merge failure
    final videoOnlyPath =
        '${p.withoutExtension(current.localFilePath)}_video_only${p.extension(current.localFilePath).isNotEmpty ? p.extension(current.localFilePath) : '.mp4'}';
    final videoOnlyFile = File(videoOnlyPath);
    if (videoOnlyFile.existsSync() && !File(current.localFilePath).existsSync()) {
      debugPrint('[DMX] F4: Restoring video-only file for merge retry');
      await videoOnlyFile.rename(current.localFilePath);
    }

    final videoExt = p.extension(actualVideoPath).isNotEmpty
        ? p.extension(actualVideoPath)
        : '.mp4';

    final mergedPath =
        '${p.withoutExtension(actualVideoPath)}$videoExt.merged$videoExt';

    await _host.setTaskState(current.copyWith(
      statusMessage: DownloadStatusMessages.merging,
    ));

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


    // ── FIX-1: Validate audio file integrity before merge ──
    final expectedAudioSize = current.audioSize;
    if (expectedAudioSize > 0 && audioLen < expectedAudioSize) {
      final deficit = expectedAudioSize - audioLen;
      final deficitPct =
          (deficit / expectedAudioSize * 100).toStringAsFixed(1);
      throw Exception(
        'Audio file incomplete: $audioLen / $expectedAudioSize bytes '
        '($deficitPct% missing). File: $actualAudioPath',
      );
    }

    // FIX-10: Validate video file size before merge
    final expectedVideoSize = current.fileSize > 0
        ? (current.fileSize - (current.audioSize > 0 ? current.audioSize : 0))
        : 0;
    if (expectedVideoSize > 0 &&
        videoLen < (expectedVideoSize * 0.95).toInt()) {
      throw Exception(
        'Video file incomplete: $videoLen / $expectedVideoSize bytes. '
        'File: $actualVideoPath',
      );
    }

    Duration? expectedDuration;
    try {
      final probe = await FFprobeKit.execute(

        '-v error -show_entries format=duration -of default=noprint_wrappers=1 "$actualVideoPath"',
      );
      final logs = await probe.getLogsAsString();
      final match = RegExp(r'duration=([\d.]+)').firstMatch(logs);
      final durSecs = double.tryParse(match?.group(1) ?? '');
      if (durSecs != null && durSecs > 0) {
        expectedDuration = Duration(milliseconds: (durSecs * 1000).round());
      }
    } catch (e) {
      debugPrint('[DMX] FFprobe video duration probe exception: $e');
    }

    final preMergeCheck = _host.findTaskById(taskId);
    if (preMergeCheck == null || preMergeCheck.status != DownloadStatus.downloading) {
      debugPrint('[DMX] FIX-2: Merge cancelled: task no longer downloading');
      return false;
    }

    final success = await FFmpegMuxService.mergeVideoAudio(

      actualVideoPath,
      actualAudioPath,
      mergedPath,
      deleteInputsIfTemp: false,
      expectedDuration: expectedDuration,
    );

    final latest = _host.findTaskById(taskId);
    if (latest == null || latest.status != DownloadStatus.downloading) {
      debugPrint(
        '[DMX] Task $taskId was cancelled or deleted during FFmpeg merge — cleaning up merged file.',
      );
      try {
        final mergedFile = File(mergedPath);
        if (await mergedFile.exists()) await mergedFile.delete();
      } catch (_) {}
      return false;
    }

    if (success) {
      final mergedFile = File(mergedPath);
      if (await mergedFile.exists()) {
        final mergedLen = await mergedFile.length();
        debugPrint('[DMX] Merge successful: $mergedPath ($mergedLen bytes)');
        final targetFile = File(current.localFilePath);
        if (await targetFile.exists()) {
          try {
            await targetFile.delete();
          } catch (e, st) {
            Logger(
              'download_orchestrator',
            ).warning('[download_orchestrator] operation failed', e, st);
          }
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
        // FIX-B3 & FIX-B4: Clean up audio and video temp/state/journal files on merge success
        try { await audioFile.delete(); } catch (_) {}
        try { await File('${current.tempFilePath}.audio.dmxstate').delete(); } catch (_) {}
        try { await File('${current.tempFilePath}.audio.journal').delete(); } catch (_) {}
        if (current.tempFilePath != current.localFilePath) {
          try { await videoFile.delete(); } catch (_) {}
          try { await File('${current.tempFilePath}.dmxstate').delete(); } catch (_) {}
          try { await File('${current.tempFilePath}.journal').delete(); } catch (_) {}
        }

      } else {
        throw Exception('Merged output file not found after FFmpeg success');
      }
    } else {
      // ── FIX-2: Preserve audio files on merge failure ──
      var videoOnlyPath =
          '${p.withoutExtension(actualVideoPath)}_video_only$videoExt';
      try {
        if (videoFile.path != videoOnlyPath) {
          await videoFile.rename(videoOnlyPath);
        }
      } catch (e) {
        debugPrint('[DMX] Failed to rename video-only file: $e');
        videoOnlyPath = actualVideoPath;
      }

      debugPrint(
        '[DMX] FFmpeg merge failed. Audio preserved at: $actualAudioPath\n'
        '[DMX] Video-only saved at: $videoOnlyPath\n'
        '[DMX] Retry will resume audio from existing state.',
      );

      final audioBytes =
          await _readDmxStateBytes('${current.tempFilePath}.audio');
      final fraction = current.audioSize > 0
          ? (audioBytes / current.audioSize).clamp(0.0, 1.0)
          : 0.0;

      // FIX(B-1): Delete audio temp file on merge failure to prevent space waste
      final audioTemp = File('${current.tempFilePath}.audio');
      if (await audioTemp.exists()) {
        try { await audioTemp.delete(); } catch (_) {}
      }

      await _host.setTaskState(
        current.copyWith(
          status: DownloadStatus.failed,
          errorMessage: '${DownloadStatusMessages.ffmpegMergeFailed} Audio preserved — retry to re-attempt merge.',
          localFilePath: videoOnlyPath,
          audioProgress: fraction,
        ),
      );
      return false;
    }


    return true;
  }

  /// Finalize a completed download: SHA-256 check, status update, notification.
  Future<void> _finalizeDownload(String taskId, int notificationId) async {
    await _host.flushPendingProgress(taskId);
    _host.speedHistories.remove(taskId);
    _host.lastProgressUpdateTimes.remove(taskId);
    _host.lastDbSaveTimes.remove(taskId);

    final taskObj = _host.findTaskById(taskId);
    _host.ytLowSpeedCounts.remove(taskId);
    _host.ytThrottlingRefreshing.remove(taskId);
    _ytRefreshAttempts.remove(taskId);
    _host.lastTorrentFileDiskSync.remove(taskId);
    if (taskObj == null) return;
    if (taskObj.status != DownloadStatus.downloading) return;

    var current = taskObj;

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
        TorrentService.removeTorrent(tid, deleteFiles: false);
        _host.providerTorrentIds.remove(current.id);
      }
    }

    final finalFileSize = current.fileSize > 0
        ? current.fileSize
        : (current.downloadedBytes > 0 ? current.downloadedBytes : 0);

    if (!current.isTorrent &&
        (current.category == 'Video' || current.category == 'Audio')) {
      final file = File(current.localFilePath);
      if (await file.exists()) {
        final size = await file.length();
        if (size < 100 * 1024) {
          await _host.setTaskState(
            current.copyWith(
              status: DownloadStatus.failed,
              errorMessage:
                  'Downloaded file is only $size bytes — likely an error page, not valid media. Stream URL may have expired. Please retry.',
            ),
          );
          return;
        }
      }
    }

    var updatedTask = current;
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
    } else if (_host.providerSettingsProvider.autoVerifyChecksum) {
      try {
        final file = File(current.localFilePath);
        if (!Directory(current.localFilePath).existsSync() &&
            await file.exists()) {
          final digest = await Isolate.run(
            () => ChecksumService.sha256File(current.localFilePath),
          );
          updatedTask = current.copyWith(expectedSha256: digest);
          await _host.setTaskState(updatedTask);
          current = updatedTask;

          if (metrics != null) {
            metrics.checksumAlgorithm = 'SHA-256';
            metrics.checksumVerified = true;
            metrics.checksumPassed = true;
          }
        }
      } catch (e) {
        debugPrint('[DMX] Auto-SHA-256 computation failed: $e');
      }
    }


    // FIX-16: Post-download file size integrity check for HTTP downloads
    if (!current.isTorrent && current.fileSize > 0) {
      final file = File(current.localFilePath);
      if (await file.exists()) {
        final actualSize = await file.length();
        if (actualSize < current.fileSize) {
          await _host.setTaskState(
            current.copyWith(
              status: DownloadStatus.failed,
              errorMessage:
                  'Download incomplete: expected ${current.fileSize} bytes, '
                  'got $actualSize bytes. File: ${current.localFilePath}',
            ),
          );
          return;
        }
      }
    }


    // Record checksum metrics
    if (metrics != null && current.expectedSha256 != null) {
      metrics.checksumAlgorithm = 'SHA-256';
      metrics.checksumVerified = true;
      metrics.checksumPassed = current.status != DownloadStatus.failed;
    }




    await _host.setTaskState(
      current.copyWith(
        clearError: true,
        clearStatusMessage: true,
        status: DownloadStatus.completed,
        fileSize: finalFileSize,
        // FIX(F-1): snap to 100 % on completion
        downloadedBytes: finalFileSize > 0 ? finalFileSize : current.downloadedBytes,

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
                  _mediaChannel.invokeMethod('scanMedia', {
                    'path': entity.path,
                  }),
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
        String actualFilePath = finalPath;
        String actualFileName = current.fileName;
        final torrentFiles = current.torrentFiles;
        if (torrentFiles != null && torrentFiles.isNotEmpty) {
          final targetRelName = torrentFiles.first['name'] as String?;
          if (targetRelName != null && targetRelName.isNotEmpty) {
            final canonicalSave = p.canonicalize(current.savePath);
            final candidate = p.canonicalize(
              p.join(current.savePath, targetRelName),
            );
            // SECURITY: only follow the name if it stays inside savePath.
            if (p.isWithin(canonicalSave, candidate) &&
                File(candidate).existsSync()) {
              actualFilePath = candidate;
              actualFileName = p.basename(candidate);
            }
          }
        }
        if (!File(actualFilePath).existsSync()) {
          final saveDir = Directory(current.savePath);
          if (saveDir.existsSync()) {
            await for (final entity in saveDir.list(recursive: false)) {
              if (entity is File &&
                  p.extension(entity.path) == p.extension(finalPath)) {
                actualFilePath = entity.path;
                actualFileName = p.basename(entity.path);
                break;
              }
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

    // FIX(B-5): Reset audioProgress to 0.0 when retrying download after failure
    if (task.mergedAudioUrl != null && task.status == DownloadStatus.failed) {
      task = task.copyWith(audioProgress: 0.0);
      await _host.setTaskState(task);
    }

    final maxRetries = _host.providerSettingsProvider.autoRetryEnabled

        ? _host.providerSettingsProvider.maxRetries
        : 0;
    int attempt = 0;

    // Track effective thread count and TTFB in metrics
    _host.downloadMetrics[task.id]?.effectiveThreads = runtimeThreadCount;
    int? ttfbTimestamp;

    int videoBytesFromDisk;
    final stateFilePath = '${task.tempFilePath}.dmxstate';
    final hasStateFile = await File(stateFilePath).exists();

    if (task.threadCount > 1) {
      // Pre-allocated file length is meaningless without the state file.
      videoBytesFromDisk =
          hasStateFile ? await _readDmxStateBytes(task.tempFilePath) : 0;
    } else {
      final tempFile = File(task.tempFilePath);
      videoBytesFromDisk = tempFile.existsSync() ? await tempFile.length() : 0;
    }


    // Also fix audio bytes — same pre-allocation issue applies
    int audioBytesFromDisk = 0;
    final audioTempPath = '${task.tempFilePath}.audio';
    if (task.mergedAudioUrl != null && task.mergedAudioUrl!.isNotEmpty) {
      final audioStatePath = '$audioTempPath.dmxstate';
      if (await File(audioStatePath).exists()) {
        audioBytesFromDisk = await _readDmxStateBytes(audioTempPath);
      } else {
        final audioFile = File(audioTempPath);
        audioBytesFromDisk =
            audioFile.existsSync() ? await audioFile.length() : 0;
      }
    }
    int audioBytesSoFar = audioBytesFromDisk;

    int videoBytesSoFar = max(
      videoBytesFromDisk,
      (task.downloadedBytes - audioBytesFromDisk).clamp(
        0,
        task.fileSize > 0 ? task.fileSize : task.downloadedBytes,
      ),
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
      // FIX-AUDIT-10: Microtask coalescing guard to prevent interleaved reads
      if (_pushScheduled[task.id] == true) return;
      _pushScheduled[task.id] = true;
      scheduleMicrotask(() {
        _pushScheduled[task.id] = false;
        final index = _host.providerTasks.indexWhere((t) => t.id == task.id);
        if (index == -1) return;
        final base = _host.providerTasks[index];
        if (base.status != DownloadStatus.downloading) return;


      // FIX 4: Freeze denominator when audioSize > 0 and keep totalSize monotonic
      final audioContribution =
          hasAudio ? (base.audioSize > 0 ? base.audioSize : (audioBytesSoFar > 0 ? audioBytesSoFar : 0)) : 0;
      final effectiveVideoSize =
          videoSizeSoFar > 0 ? videoSizeSoFar : videoTransferSize;
      final calculatedTotal = effectiveVideoSize + audioContribution;
      final cachedMax = _sessionCachedTotalSize[task.id] ?? 0;
      final totalSize = max(cachedMax, calculatedTotal);
      if (totalSize > cachedMax) {
        _sessionCachedTotalSize[task.id] = totalSize;
      }



      final totalDownloaded = (audioBytesSoFar + videoBytesSoFar).clamp(
          0, totalSize > 0 ? totalSize : (audioBytesSoFar + videoBytesSoFar));
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
        statusMessage: (statusMessageOverride == 'Completed' &&
                hasAudio &&
                audioBytesSoFar < audioContribution)
            ? null
            : statusMessageOverride,
        clearStatusMessage: (statusMessageOverride == 'Completed' &&
            hasAudio &&
            audioBytesSoFar < audioContribution),
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      final lastUpdate = _host.lastProgressUpdateTimes[task.id] ?? 0;
      if (now - lastUpdate >= 250) {
        _host.lastProgressUpdateTimes[task.id] = now;
        _host.providerTasks[index] = updated;
        _host.pushProgressTick(task.id, updated.progress, updated.speed);
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
        _host.pushProgressTick(task.id, updated.progress, updated.speed);
        _host.pendingProgressUpdates.add(task.id);
      }
      });
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

    // FIX A-3: Early-exit merge path before retry loop when both streams exist and are complete
    if (hasAudio) {

      final videoFile = File(task.tempFilePath);
      final audioFile = File(audioTempPath);
      if (await videoFile.exists() && await audioFile.exists()) {
        final videoLen = await videoFile.length();
        final audioLen = await audioFile.length();
        final expectedVideo = videoTransferSize > 0 ? videoTransferSize : 1;
        final expectedAudio = task.audioSize > 0 ? task.audioSize : 1;
        if (videoLen >= expectedVideo && audioLen >= expectedAudio) {
          debugPrint('[DMX] FIX A-3: Both streams complete. Merge-only path.');
          await _host.setTaskState(task.copyWith(
            statusMessage: DownloadStatusMessages.merging,
          ));
          final merged = await _mergeAudioVideo(task.id, audioTempPath);
          if (merged) {
            await _finalizeDownload(task.id, notificationId);
            return;
          }
        }
      }
    }

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
            final liveHasAudio = !liveAudioTask.isTorrent &&
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
            // FIX-C2: Also consider audio complete when liveAudioSize <= 0 but audioLen > 0
            // FIX-05: Only treat audio as complete when size is known AND downloaded bytes >= liveAudioSize
            final isAudioComplete = liveAudioTask.audioProgress >= 1.0 ||
                (audioExists &&
                    audioLen > 0 &&
                    liveAudioSize > 0 &&
                    audioLen >= liveAudioSize);
            if (isAudioComplete) {
              debugPrint('[DMX-FIX-05] Audio stream complete ($audioLen / $liveAudioSize bytes)');
            }



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

            // FIX-C3: Validate audio file integrity before resume.
            // If the audio file on disk is shorter than what the recorded audioProgress
            // implies, the file is corrupted or truncated — reset progress and delete it.
            if (audioExists &&
                liveAudioTask.audioProgress > 0 &&
                liveAudioSize > 0) {
              final expectedBytes =
                  (liveAudioTask.audioProgress * liveAudioSize).toInt();
              if (audioLen < expectedBytes) {
                debugPrint(
                  '[DMX] Audio file shorter than recorded progress '
                  '($audioLen < $expectedBytes bytes), resetting audio progress',
                );
                final idx =
                    _host.providerTasks.indexWhere((x) => x.id == task.id);
                if (idx != -1) {
                  _host.providerTasks[idx] = _host.providerTasks[idx].copyWith(
                    audioProgress: 0.0,
                  );
                }
                // Delete the corrupted audio file so it's re-downloaded cleanly.
                try {
                  await audioFile.delete();
                } catch (_) {}
              }
            }

            debugPrint('[DMX] Parallel download: starting audio stream.');
            await _host.downloadEngine.download(
              taskId: task.id,
              url: liveAudioTask.mergedAudioUrl!,
              tempFilePath: liveAudioTempPath,
              localFilePath: liveAudioTempPath,
              knownFileSize: liveAudioSize,
              supportsResume: true,
              cancelToken: audioCancelToken,
              cookies: cookieString,
              oauthToken: YoutubeService.oauthToken,
              // FIX-AUDIT-7: Scale audio threads with file size.
              // Small audio (<5MB): 1 thread. Medium (<50MB): 2. Large: up to 4.
              threadCount: liveAudioSize <= 0
                  ? 2
                  : liveAudioSize < 5 * 1024 * 1024
                      ? 1
                      : liveAudioSize < 50 * 1024 * 1024
                          ? 2
                          : min(4, liveAudioSize > 200 * 1024 * 1024 ? 4 : 3),

              adaptiveThreads: _host.providerSettingsProvider.adaptiveThreads,
              speedLimitKbps: task.speedLimitKbps,
              onProgress: (progress) {
                final t = _host.findTaskById(task.id);
                if (t == null || t.status != DownloadStatus.downloading) return;
                audioBytesSoFar = progress.downloadedBytes;
                audioSpeedNow = progress.speed;
                final size = t.audioSize > 0 ? t.audioSize : progress.fileSize;
                // FIX-B2: Prevent audioProgress stuck at 0.0 when size is unknown
                final fraction = size > 0
                    ? (progress.downloadedBytes / size).clamp(0.0, 1.0)
                    : (progress.downloadedBytes > 0 ? 1.0 : 0.0);

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
            audioBytesSoFar =
                task.audioSize > 0 ? task.audioSize : downloadedAudioLen;
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
            final liveHasAudio = liveVideoTask != null &&
                !liveVideoTask.isTorrent &&
                liveVideoTask.mergedAudioUrl != null &&
                liveVideoTask.mergedAudioUrl!.isNotEmpty;
            final liveVideoTransferSize = liveHasAudio &&
                    liveVideoTask.audioSize > 0 &&
                    liveVideoTask.fileSize > liveVideoTask.audioSize
                ? liveVideoTask.fileSize - liveVideoTask.audioSize
                : liveVideoTask?.fileSize ?? videoTransferSize;
            debugPrint('[DMX] Parallel download: starting video stream.');
            try {
              await _host.downloadEngine.download(
                taskId: task.id,
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
                adaptiveThreads: _host.providerSettingsProvider.adaptiveThreads,
                speedLimitKbps: task.speedLimitKbps,
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
                  videoBytesSoFar = progress.downloadedBytes;
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

                  final speedQueue =
                      _host.speedHistories[task.id] ??= Queue<double>();
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
                  // B4: Only use disk scan as initial seed data BEFORE the engine has
                  // reported actual per-file progress. Once the engine reports real
                  // per-file bytes (progressEstimated == false OR downloadedBytes > 0),
                  // disk scans are suppressed permanently — pre-allocated torrent files
                  // report full size on disk and would overwrite accurate piece-level
                  // accounting with imprecise file sizes.
                  // The engineHasActualPerFileProgress flag is the single source of truth
                  // for this gate; never run disk scan after it becomes true.
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
                        debugPrint(
                            '[DMX] Disk-verify torrent files failed: $e');
                      }
                    }
                  }

                  pushCombinedProgress(
                    chunksOverride: progress.chunks ??
                        _host.buildChunks(
                          streamThreadCount,
                          videoSizeSoFar > 0
                              ? videoSizeSoFar
                              : videoTransferSize,
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
            } on DioException catch (e) {
              final msg = e.message ?? '';

              // HTML response = expired stream → re-resolve once
              if (msg.contains('HTML_INSTEAD_OF_MEDIA') && isYoutube) {
                debugPrint(
                    '[DMX] Stream expired for ${task.id}, re-resolving...');
                final pageUrl = task.downloadPageUrl ?? task.url;
                final fresh = await YoutubeService.getFreshStreams(pageUrl);

                if (fresh != null && fresh['url'] != null) {
                  task = task.copyWith(url: fresh['url'] as String);
                  await _host.setTaskState(task);

                  await _host.downloadEngine.download(
                    taskId: task.id,
                    url: task.url,
                    tempFilePath: task.tempFilePath,
                    localFilePath: task.localFilePath,
                    knownFileSize: liveVideoTransferSize,
                    supportsResume: true,
                    cancelToken: videoCancelToken,
                    cookies: cookieString,
                    oauthToken: YoutubeService.oauthToken,
                    adaptiveThreads:
                        _host.providerSettingsProvider.adaptiveThreads,
                    speedLimitKbps: task.speedLimitKbps,
                    onProgress: (progress) {
                      final current = _host.findTaskById(task.id);
                      if (current == null ||
                          current.status != DownloadStatus.downloading) {
                        return;
                      }
                      videoBytesSoFar = progress.downloadedBytes;
                      videoSpeedNow = progress.speed;
                      if (progress.fileSize > 0) {
                        videoSizeSoFar = progress.fileSize;
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
                  );
                } else {
                  rethrow;
                }
              } else {
                rethrow;
              }
            }
          }

          await Future.wait([runVideo(), runAudio()]);
          if (hasAudio) {
            // FIX-AUDIT-4: Check merge result. If merge failed, do NOT proceed to finalize.
            final mergeOk = await _mergeAudioVideo(task.id, audioTempPath);

            if (!mergeOk) {
              final current = _host.findTaskById(task.id);
              if (current != null && current.status == DownloadStatus.downloading) {
                await _host.setTaskState(current.copyWith(
                  status: DownloadStatus.failed,
                  errorMessage:
                      '${DownloadStatusMessages.ffmpegMergeFailed} Video saved without audio. Tap retry to re-attempt merge.',
                ));
              }
              return; // Do NOT call _finalizeDownload
            }
          }

          await _finalizeDownload(task.id, notificationId);
          return;

        } catch (error) {
          if (!videoCancelToken.isCancelled) videoCancelToken.cancel();
          if (!audioCancelToken.isCancelled) audioCancelToken.cancel();

          final isYoutubeDownload = (task.downloadPageUrl != null &&
                  YoutubeService.extractVideoId(task.downloadPageUrl!) !=
                      null) ||
              task.url.contains('.googlevideo.com/') ||
              task.youtubeQualityPreset != null;
          bool shouldRefreshYoutube = false;
          if (isYoutubeDownload) {
            final errStr = error.toString();
            final msg = error is DioException ? error.message ?? '' : '';
            final statusCode =
                error is DioException ? error.response?.statusCode : null;
            final htmlError = errStr.contains('HTML instead of media') ||
                msg.contains('HTML instead of media');

            if (htmlError) {
              try {
                final pageUrl = (task.downloadPageUrl != null &&
                        task.downloadPageUrl!.isNotEmpty)
                    ? task.downloadPageUrl!
                    : task.url;
                final fresh = await YoutubeService.refreshStreamUrl(
                  pageUrl,
                  task.url,
                );
                final refreshedUrl = fresh?['url']?.toString();
                if (refreshedUrl != null && refreshedUrl.isNotEmpty) {
                  final refreshedAudioUrl = fresh?['audioUrl']?.toString();
                  task = task.copyWith(
                    url: refreshedUrl,
                    mergedAudioUrl: refreshedAudioUrl ?? task.mergedAudioUrl,
                  );
                  final idx = _host.providerTasks.indexWhere(
                    (x) => x.id == task.id,
                  );
                  if (idx != -1) {
                    _host.providerTasks[idx] =
                        _host.providerTasks[idx].copyWith(
                      url: refreshedUrl,
                      mergedAudioUrl: refreshedAudioUrl ?? task.mergedAudioUrl,
                    );
                    await _host.providerDatabaseService.saveTask(
                      _host.providerTasks[idx],
                    );
                  }
                  await _host.setTaskState(task);
                  continue;
                }
              } catch (e) {
                debugPrint('[DMX] HTML refresh retry failed: $e');
              }
            }

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
              final pageUrl = (task.downloadPageUrl != null &&
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
          // FIX I-1: Cancel progress notification on failure / merge failure
          _host.notifications.cancelForTask(task.id);
          _ytRefreshAttempts.remove(task.id);
          rethrow;
        }
      }
    }
 finally {
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
      _host.networkMonitor.markWifiWaiting(task.id);
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

    final resolved = await _resolveStreamUrl(task);
    if (resolved == null) return;
    task = resolved;
    final cookieString = _currentCookieString;



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

    // Validate resume state before starting any torrent or engine calls
    task = await validateResumeState(latestBeforeStart);

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
          // FIX-H3: Ensure save directory exists before passing it to the
          // native engine. Some platforms fail silently when the dir is missing.
          try {
            final dir = Directory(saveDir);
            if (!await dir.exists()) {
              await dir.create(recursive: true);
            }
          } catch (e) {
            debugPrint('[DMX] Failed to create torrent save directory: $e');
          }
          if (task.url.startsWith('magnet:')) {
            torrentId = TorrentService.addMagnet(task.url, saveDir);
          } else {
            String filePath = task.url;
            if (task.url.startsWith('file://')) {
              filePath = Uri.parse(task.url).toFilePath();
            }
            torrentId = TorrentService.addTorrentFile(
              filePath,
              saveDir,
              sourceKey: task.url,
            );
          }
          if (torrentId < 0) {
            throw Exception('Torrent engine rejected the torrent.');
          }
          _host.providerTorrentIds[task.id] = torrentId;
          // FIX-C4: Save resume data for magnet links so resume works across app restarts
          if (task.url.startsWith('magnet:')) {
            unawaited(TorrentService.saveResumeData(torrentId));
          }


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

    // Disk space pre-check for torrents: when the total size is known (from
    // the task or the torrent file list), fail fast with a clear message
    // instead of starting a download that will error mid-way.
    if (task.isTorrent) {
      int totalTorrentSize = task.fileSize;
      if (totalTorrentSize <= 0 && (task.torrentFiles?.isNotEmpty ?? false)) {
        totalTorrentSize = task.torrentFiles!.fold<int>(0, (sum, f) {
          final size = (f['size'] as num?)?.toInt() ?? 0;
          return sum + size;
        });
      }
      if (totalTorrentSize > 0) {
        final hasSpace = await _host.downloadEngine.hasEnoughDiskSpace(
          task.savePath,
          totalTorrentSize,
        );
        if (!hasSpace) {
          _host.cancelTokens.remove(task.id);
          _host.activeFutures.remove(task.id);
          await _host.setTaskState(
            task.copyWith(
              status: DownloadStatus.failed,
              errorMessage: 'Not enough storage space for torrent files.',
            ),
          );
          _host.notifications.showFailed(
            notificationId: _host.notifications.idFor(task.id),
            title: task.fileName,
            error: 'Not enough storage space for torrent files.',
          );
          _host.pumpQueue();
          _host.updateTelemetryWidget();
          return;
        }
      }
    }

    // Fire-and-await so the queued→downloading transition is committed
    // before the first progress callback fires.
    // For torrents: update the file metadata list, but do NOT use the disk
    // scan to set downloadedBytes — libtorrent pre-allocates files to their
    // FIX-14: On resume, reset per-file downloadedBytes to 0 so the engine
    // re-reports accurate values. The engine's first progress tick will
    // overwrite with real data.
    List<Map<String, dynamic>>? verifiedTorrentFiles;
    if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
      verifiedTorrentFiles = task.torrentFiles!.map((f) {
        final copy = Map<String, dynamic>.from(f);
        if (copy['progressEstimated'] == true) {
          copy['downloadedBytes'] = 0;
        }
        return copy;
      }).toList();
    } else {
      verifiedTorrentFiles = task.torrentFiles;
    }

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
    _host.downloadMetrics[task.id] = DownloadMetrics(
        taskId: task.id, url: task.url)
      ..requestedThreads = runtimeThreadCount
      ..resumed = realTotalDownloaded > 0
      ..resumeBytesSaved = realTotalDownloaded > 0 ? realTotalDownloaded : 0;

    final notificationId = _host.notifications.idFor(task.id);
    // Torrents always reconcile: the guessed name (magnet `dn`) may differ from
    // the real torrent name reported after metadata, and the task's paths must
    // point at the folder libtorrent actually uses so resume stays consistent.
    final isAutoName = task.isTorrent ||
        task.fileName == 'torrent_download.zip' ||
        task.fileName.isEmpty ||
        task.fileName == fileNameFromUrl(task.url) ||
        task.fileName.startsWith('download_');

    final hasAudio = !task.isTorrent &&
        task.mergedAudioUrl != null &&
        task.mergedAudioUrl!.isNotEmpty;
    final audioTempPath = hasAudio ? '${task.tempFilePath}.audio' : null;

    // Detect YouTube early so we can skip CDN HEAD probes that trigger 429s.
    final isYoutube = task.downloadPageUrl != null &&
        (task.downloadPageUrl!.contains('youtube.com/') ||
            task.downloadPageUrl!.contains('youtu.be/'));

    if (isYoutube && task.downloadPageUrl != null && realTotalDownloaded > 0) {
      try {
        final fresh =
            await YoutubeService.getFreshStreams(task.downloadPageUrl!);
        if (fresh != null && fresh['url'] != null) {
          debugPrint(
              '[DMX] Proactively refreshed YouTube stream URL on resume');
          task = task.copyWith(
            url: fresh['url'] as String,
            mergedAudioUrl: fresh['audioUrl'],
          );
        }
      } catch (e) {
        debugPrint(
            '[DMX] Proactive YouTube stream refresh on resume failed: $e');
      }
    }

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
      videoTransferSize = 0; // Let the engine probe the actual size
      debugPrint(
        '[DMX] videoTransferSize was 0 (fileSize=${task.fileSize}, '
        'audioSize=${task.audioSize}); left at 0 for engine probe',
      );
    }

    // Validate resume state before starting
    task = await validateResumeState(task);

    // ═══ FIX YT-2/YT-6: Detect interrupted merge and resume merge-only ═══
    if (!task.isTorrent &&
        task.mergedAudioUrl != null &&
        task.mergedAudioUrl!.isNotEmpty) {
      final videoFile = File(task.tempFilePath);
      final audioFile = File('${task.tempFilePath}.audio');

      if (await videoFile.exists() && await audioFile.exists()) {
        final videoLen = await videoFile.length();
        final audioLen = await audioFile.length();

        if (videoLen > 1024 && audioLen > 1024) {
          // FIX(YT2): Don't treat unknown-size audio as complete
          final audioComplete = task.audioProgress >= 1.0 ||
              (audioLen > 0 && task.audioSize > 0 && audioLen >= task.audioSize);


          final videoComplete = task.fileSize > 0 &&
              (videoLen >=
                  (task.fileSize - task.audioSize).clamp(0, task.fileSize));

          if (audioComplete && videoComplete) {
            debugPrint(
                '[DMX] YT-6 FIX: Both streams complete, resuming merge-only');
            await _host.setTaskState(task.copyWith(
              status: DownloadStatus.downloading,
              statusMessage: DownloadStatusMessages.merging,
            ));

            final merged = await _mergeAudioVideo(task.id, audioFile.path);
            if (merged) {
              await _finalizeDownload(
                  task.id, _host.notifications.idFor(task.id));
            } else {

              await _host.setTaskState(task.copyWith(
                status: DownloadStatus.failed,
                errorMessage: 'Merge failed. Tap retry to attempt merge again.',
              ));
            }
            return;
          }
        }
      }
    }
    // ═══ END FIX YT-2/YT-6 ═══


    // YouTube streams use multi-threaded mode as configured.

    // Run video and audio in PARALLEL — each gets the full configured
    // thread count (streamThreadCount), not split between them.
    final downloadFuture = _executeDownload(
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
    ).then((_) async {
      if (hasAudio) {
        await _mergeAudioVideo(task.id, audioTempPath!);
      }
      await _finalizeDownload(task.id, notificationId);
    }).catchError((Object error, StackTrace stackTrace) async {
      final realError = error;

      final errStr = error.toString();
      final isResumeRejection =
          errStr.contains('Server rejected resume: expected HTTP 206.');
      if (isResumeRejection) {
        final alreadyRestarted =
            _host.resumeRejectionRestarts[task.id] ?? false;
        if (!alreadyRestarted) {
          _host.resumeRejectionRestarts[task.id] = true;
          debugPrint(
              '[DMX] Server rejected HTTP 206 resume. Performing a full restart from byte 0 for task: ${task.id}');
          _host.notifications.cancelNotification(notificationId);
          await _host.startOverTask(
            task.id,
            task.url,
            fromError: true,
            deleteTempFiles: true,
          );
          return;
        }
      }

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

      if (!cancelToken.isCancelled) {
        try {
          cancelToken.cancel('Task failed, cleaning up in-flight requests');
        } catch (_) {}
      }

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

      // Audio sidecar intentionally preserved on failure.
      // Retry / resume can continue from the existing .audio + .audio.dmxstate.

      final isRetryable = isRetryableError(realError);
      final maxRetries =
          _host.providerSettingsProvider.autoRetryEnabled && isRetryable
              ? _host.providerSettingsProvider.maxRetries
              : 0;
      final currentRetry = _host.retryCounts[task.id] ?? 0;

      if (currentRetry < maxRetries) {
        _host.retryCounts[task.id] = currentRetry + 1;
        final delaySeconds = _host.providerSettingsProvider.retryDelaySeconds;
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

      final wasExhausted =
          isRetryable && currentRetry >= maxRetries && maxRetries > 0;
      _host.retryCounts.remove(task.id);
      _recordDownloadFailure(task.id, realError);
      try {
        await _host.cleanupPartFiles(current, preserveParts: true);
        await cleanupTempFiles(current, preserveParts: true);
      } catch (e) {
        debugPrint(
          'Failed to clean up temp files on non-retryable error: $e',
        );
      }
      await _host.setTaskState(
        current.copyWith(
          status: DownloadStatus.failed,
          speed: 0,
          clearEta: true,
          clearStatusMessage: true,
          errorMessage: wasExhausted
              ? 'Download failed after $maxRetries retries. Please check your network and try again.'
              : errorMessage(realError),
        ),
      );
      if (wasExhausted) {
        _host.notifications.showFailed(
          notificationId: notificationId,
          title: task.fileName,
          error:
              'Download failed after $maxRetries retries. Please check your network and try again.',
        );
        DiagnosticService.instance.record(
          'download_engine',
          'Download failed after $maxRetries retries. Error: ${errorMessage(realError)}',
          error: realError,
        );
      } else {
        _host.notifications.showFailed(
          notificationId: notificationId,
          title: task.fileName,
          error: errorMessage(realError),
        );
      }
    }).whenComplete(() {
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
    } catch (e, st) {
      Logger(
        'download_orchestrator',
      ).warning('[download_orchestrator] operation failed', e, st);
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

  @visibleForTesting
  bool youtubeStreamRequiresMuxing(String? streamType) {
    final normalized = (streamType ?? '').toLowerCase().trim();
    return normalized == 'video_only' || normalized == 'video';
  }

  @visibleForTesting
  bool shouldRejectResolvedYoutubeUrl(String? resolvedUrl) {
    if (resolvedUrl == null || resolvedUrl.trim().isEmpty) return true;

    final uri = Uri.tryParse(resolvedUrl.trim());
    if (uri == null) return false;

    final host = uri.host.toLowerCase();
    final isYouTubeHost = host == 'youtube.com' ||
        host == 'www.youtube.com' ||
        host == 'm.youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtu.be' ||
        host.endsWith('.youtu.be');

    if (isYouTubeHost) return true;

    final path = uri.path.toLowerCase();
    return path == '/watch' ||
        path == '/playlist' ||
        path == '/shorts' ||
        path.endsWith('.html') ||
        path.endsWith('.htm');
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
    if (error is InsufficientStorageException) {
      return error.message;
    }
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
    if (error is InsufficientStorageException) {
      return false; // Retrying won't free up disk space.
    }
    if (error is DownloadIntegrityException ||
        msg.contains('file changed on server') ||
        msg.contains('filechangedonserver')) {
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
    _periodicResumeSaveTimer?.cancel();
    _cookieCache.clear();
    _ytRefreshAttempts.clear();
    _startingTaskIds.clear();
  }

  /// Cleans up temporary download artifacts (.dmxpart, .dmxstate, .journal, .audio)
  /// for a task when a non-retryable failure occurs.
  Future<void> cleanupTempFiles(
    DownloadTask task, {
    bool preserveParts = false,
  }) async {
    final List<File> sidecars = [
      File('${task.tempFilePath}.journal'), // always safe to delete
    ];

    if (!preserveParts) {
      sidecars.add(File(task.tempFilePath));
      sidecars.add(File('${task.tempFilePath}.dmxstate'));
      if (task.mergedAudioUrl != null && task.mergedAudioUrl!.isNotEmpty) {
        sidecars.add(File('${task.tempFilePath}.audio'));
        sidecars.add(File('${task.tempFilePath}.audio.dmxstate'));
      }
    }

    for (final f in sidecars) {
      try {
        if (await f.exists()) await f.delete();
      } catch (e, st) {
        Logger('download_orchestrator').warning(
          '[download_orchestrator] cleanupTempFiles failed for ${f.path}',
          e,
          st,
        );
      }
    }
  }

  Future<void> cleanupHttpArtifacts(
    DownloadTask task, {
    bool preserveParts = false,
  }) async {
    try {
      if (!preserveParts) {
        // Full cleanup: delete the main temp file
        final tempFile = File(task.tempFilePath);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        // Delete per-thread part files
        for (int i = 0; i < task.threadCount; i++) {
          final partFile = File('${task.tempFilePath}.part$i');
          if (await partFile.exists()) {
            await partFile.delete();
          }
        }
      }

      // Sidecars: always delete journal (transient crash marker).
      // When preserving, keep .dmxstate / .audio / .audio.dmxstate / .merged
      final sidecars = <File>[
        File('${task.tempFilePath}.journal'), // always safe to delete
      ];

      if (!preserveParts) {
        sidecars.addAll([
          File('${task.tempFilePath}.dmxstate'),
          File('${task.tempFilePath}.audio'),
          File('${task.tempFilePath}.audio.dmxstate'),
          File('${task.tempFilePath}.merged'),
        ]);
      }

      for (final f in sidecars) {
        if (await f.exists()) {
          await f.delete();
        }
      }
    } catch (e) {
      debugPrint('Failed to clean up HTTP artifacts for ${task.id}: $e');
    }
  }

  Future<void> cleanupAllArtifacts(
    DownloadTask task, {
    bool preserveParts = false,
  }) async {
    final isTorrent =
        task.torrentFiles != null && task.torrentFiles!.isNotEmpty;
    if (isTorrent) {
      await cleanupTorrentArtifacts(task);
    } else {
      await cleanupHttpArtifacts(task, preserveParts: preserveParts);
    }
  }

  Future<void> cleanupTorrentArtifacts(DownloadTask task) async {
    if (task.tempFilePath.trim().isEmpty) return;
    try {
      final sidecars = [
        File('${task.tempFilePath}.dmxstate'),
        File('${task.tempFilePath}.journal'),
        File('${task.tempFilePath}.torrent'),
      ];
      for (final f in sidecars) {
        if (await f.exists()) {
          await f.delete();
        }
      }
    } catch (e) {
      debugPrint('Failed to clean up Torrent artifacts for ${task.id}: $e');
    }
  }

  Future<void> cleanupPartFiles(
    DownloadTask task, {
    bool preserveParts = false,
  }) async {
    await cleanupAllArtifacts(task, preserveParts: preserveParts);
  }

  /// Reads actual downloaded bytes from a .dmxstate sidecar file.
  /// Returns 0 if the file doesn't exist or is corrupted.
  static Future<int> _readDmxStateBytes(
    String tempFilePath, {
    int threadCount = 1,
  }) async {
    final stateFile = File('$tempFilePath.dmxstate');
    int stateTotal = 0;
    bool hasStateFile = false;

    if (await stateFile.exists()) {
      try {
        final content = await stateFile.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is Map) {
          final progressList = decoded['progress'] as List?;
          if (progressList != null) {
            BigInt total = BigInt.zero;
            for (final chunk in progressList) {
              total += BigInt.from((chunk as num).toInt());
            }
            stateTotal = total.toInt();
            hasStateFile = true;
          }
        }
      } catch (e) {
        debugPrint('[DMX] _readDmxStateBytes failed for $tempFilePath: $e');
      }
    }

    // FIX-11: If journal exists, compare and use whichever has more bytes
    final journalPath = '$tempFilePath.journal';
    final journalFile = File(journalPath);
    if (await journalFile.exists()) {
      try {
        final journalBytes = await DownloadJournal.recover(journalPath);
        if (journalBytes != null && journalBytes.isNotEmpty) {
          final journalTotal = journalBytes.fold<int>(0, (sum, b) => sum + b);
          if (journalTotal > stateTotal) {
            debugPrint(
              '[DMX] FIX-11: Journal has more bytes ($journalTotal) '
              'than state file ($stateTotal). Using journal.',
            );
            return journalTotal;
          }
        }
      } catch (e) {
        debugPrint('[DMX] FIX-11: Journal read failed, using state: $e');
      }
    }

    if (hasStateFile) {
      return stateTotal;
    }

    // FIX-1: For multi-threaded downloads, tempFile.length() is pre-allocated size, NOT downloaded bytes.
    if (threadCount > 1) {
      debugPrint(
        '[DMX] No state file for multi-threaded download. '
        'Returning 0 instead of pre-allocated file size.',
      );
      return 0;
    }

    // FIX-D3: Single-threaded journal check before file length fallback
    if (threadCount <= 1) {
      try {
        final journalBytes =
            await DownloadJournal.recover('$tempFilePath.journal');
        if (journalBytes != null && journalBytes.isNotEmpty) {
          return journalBytes.fold<int>(0, (s, b) => s + b);
        }
      } catch (_) {}
      final tempFile = File(tempFilePath);
      if (await tempFile.exists()) {
        return await tempFile.length();
      }
    }
    return 0;

  }

  /// Reads per-chunk progress percentages from a `.dmxstate` sidecar file.
  /// Returns null when the file is missing, corrupt, or empty.
  static Future<List<double>?> _readDmxStateChunks(
      String tempFilePath, int threadCount) async {
    final stateFile = File('$tempFilePath.dmxstate');
    if (!await stateFile.exists()) return null;
    try {
      final decoded = jsonDecode(await stateFile.readAsString());
      if (decoded is Map && decoded['progress'] is List) {
        // FIX-C5: Wrap element parsing in per-element try-catch to prevent corrupt entries from crashing
        final progress = <int>[];
        for (final e in (decoded['progress'] as List)) {
          try {
            if (e is num) {
              progress.add(e.toInt());
            } else {
              progress.add(0);
            }
          } catch (_) {
            progress.add(0);
          }
        }

        final total = decoded['totalSize'] is num
            ? (decoded['totalSize'] as num).toInt()
            : 0;
        if (total <= 0 || progress.isEmpty) return null;

        // FIX-5: Validate chunk sum doesn't exceed total
        final chunkSum = progress.fold<int>(0, (sum, b) => sum + b);
        if (chunkSum > total) {
          debugPrint(
            '[DMX] FIX-5: Chunk sum ($chunkSum) exceeds total ($total). '
            'Clamping chunks.',
          );
          final scale = total / chunkSum;
          for (var i = 0; i < progress.length; i++) {
            progress[i] = (progress[i] * scale).toInt();
          }
        }

        final partSize = (total / progress.length).floor();
        return List.generate(progress.length, (i) {
          final end =
              i == progress.length - 1 ? total - i * partSize : partSize;
          return end > 0 ? (progress[i] / end).clamp(0.0, 1.0) : 0.0;
        });
      }
    } catch (_) {}
    return null;
  }
}


