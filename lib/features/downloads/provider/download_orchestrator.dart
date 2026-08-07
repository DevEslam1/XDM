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
import '../../../core/services/site_intelligence/site_intelligence_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/semaphore.dart';
import '../../../core/utils/url_utils.dart';
import '../../../shared/accessibility/xdm_announcer.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';
import 'download_provider.dart';
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
            TorrentService.resumeBlobFor,
            (tid) {
              // FIX-T1: Persist per-file progress for resume after app kill
              if (_host.providerTasks.isEmpty) return null;
              final matching = _host.providerTasks.where(
                (t) => _host.providerTorrentIds[t.id] == tid,
              );
              if (matching.isEmpty) return null;
              return matching.first.torrentFiles;
            },
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

  void clearPushScheduled(String taskId) {
    _pushScheduled.remove(taskId);
  }

  void clearSessionCachedTotalSize(String taskId) {
    _sessionCachedTotalSize.remove(taskId);
  }

  void clearStartingFlag(String taskId) {
    _startingTaskIds.remove(taskId);
  }

  void dispose() {
    _periodicResumeSaveTimer?.cancel();
    _periodicResumeSaveTimer = null;
  }

  @visibleForTesting
  void evictStaleCookies() {
    final now = DateTime.now();
    _cookieCache.removeWhere(
      (_, v) => now.difference(v.timestamp) >= const Duration(minutes: 5),
    );
    if (_cookieCache.length >= _cookieCacheMaxSize) {
      final oldestKey = _cookieCache.entries
          .reduce(
              (a, b) => a.value.timestamp.isBefore(b.value.timestamp) ? a : b)
          .key;
      _cookieCache.remove(oldestKey);
    }
  }

  @visibleForTesting
  Map<String, ({String cookie, DateTime timestamp})> get cookieCache =>
      _cookieCache;
  static const int _cookieCacheMaxSize = 50;

  @visibleForTesting
  Future<DownloadTask> validateResumeState(DownloadTask task) async {
    // Torrents use libtorrent resume, not .dmxstate
    if (task.isTorrent) {
      debugPrint(
          '[DMX-FIX-02] Torrent task ${task.id}: skipping .dmxstate validation');
      // FIX-T3: Minimal torrent validation
      try {
        final saveDir = Directory(task.savePath);
        if (!await saveDir.exists()) {
          debugPrint(
              '[FIX-T3] Torrent save directory missing: ${task.savePath}');
          return task.copyWith(
            status: DownloadStatus.failed,
            errorMessage:
                'Torrent save directory missing. Please re-add the torrent.',
          );
        }
        // Validate torrentFiles list integrity
        if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
          final hasInvalidEntry = task.torrentFiles!.any((f) {
            final name = f['name'] as String?;
            final length = f['length'] as num?;
            return name == null || name.isEmpty || length == null || length < 0;
          });
          if (hasInvalidEntry) {
            debugPrint(
                '[FIX-T3] Torrent files list has invalid entries, clearing');
            return task.copyWith(clearTorrentFiles: true);
          }
        }
      } catch (e) {
        debugPrint('[FIX-T3] Torrent validation error: $e');
      }
      return task;
    }

    try {
      if (task.downloadedBytes > 0 || task.tempFilePath.isNotEmpty) {
        final result = await StateStore.loadOrCreate(
          task.tempFilePath,
          url: task.url,
          threadCount: task.threadCount,
          knownFileSize: task.fileSize,
        );

        final state = result.state;
        if (state.downloadedBytes != task.downloadedBytes ||
            result.diskAdjusted ||
            result.migratedFrom != null) {
          task = task.copyWith(
            downloadedBytes: state.downloadedBytes,
            chunks: state.chunkRatios,
            statusMessage: result.migratedFrom != null
                ? 'Resumed from legacy state'
                : null,
          );
          // FIX-TESTS: Delete a stale/unusable state file when progress was
          // recovered as 0 (corrupt, unparseable, or mismatched legacy state).
          // Without this, the unusable file lingers and every later resume
          // re-collapses to the same zero-progress fallback.
          final staleStateFile = (result.created ||
                  result.diskAdjusted ||
                  (result.migratedFrom != null)) &&
              state.downloadedBytes == 0;
          if (staleStateFile) {
            final stateFile = File('${task.tempFilePath}.dmxstate');
            if (await stateFile.exists()) {
              try {
                await stateFile.delete();
              } catch (_) {}
            }
          }
          await _host.setTaskState(task);
        }
      }

      if (task.mergedAudioUrl != null && task.mergedAudioUrl!.isNotEmpty) {
        final audioPath = '${task.tempFilePath}.audio';
        if (!await File(audioPath).exists()) {
          if (task.audioProgress > 0) {
            task = task.copyWith(audioProgress: 0.0);
            await _host.setTaskState(task);
          }
        } else {
          final validated = await DownloadProvider.validateAudioProgress(task);
          if (validated.audioProgress != task.audioProgress) {
            await _host.setTaskState(validated);
            task = validated;
          }
        }
      }
    } catch (e) {
      debugPrint('[DMX] StateStore validation failed: $e');
    }

    return task;
  }

  final Map<String, int> _ytRefreshAttempts = {};

  int get pendingStartCount => _startingTaskIds.length;
  bool isTaskPendingStart(String taskId) => _startingTaskIds.contains(taskId);

  bool startTask(DownloadTask task) {
    if (_host.cancelTokens.containsKey(task.id)) return false;
    if (_startingTaskIds.contains(task.id)) return false;
    _startingTaskIds.add(task.id);
    try {
      unawaited(_runStartTaskBody(task));
    } catch (_) {
      _startingTaskIds.remove(task.id);
      rethrow;
    }
    return true;
  }

  Future<void> _runStartTaskBody(DownloadTask task) async {
    try {
      await _startTaskBody(task);
    } finally {
      _startingTaskIds.remove(task.id);
      // M6: _startTaskBody may return early without consuming a slot (task no
      // longer queued, stream resolution rejected, cancelled mid-gap). Re-pump
      // the queue so the freed concurrency slot is handed to the next queued
      // task instead of idling until an unrelated event triggers a pump.
      // pumpQueue() coalesces re-entry and early-exits when the cap is met.
      _host.pumpQueue();
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

    // FIX-INTEL: Use site intelligence to guide resolution and headers
    final analysis = SiteIntelligenceService().analyzeUrl(task.url);

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
          final isRetry = (_host.retryCounts[task.id] ?? 0) > 0 ||
              task.status == DownloadStatus.failed;
          // H2: Resuming with stored progress must not burn an engine attempt
          // on an expired stream URL. Refresh the video/audio URLs proactively
          // before the engine starts so a stale signed URL cannot kill the
          // resume mid-way.
          final isResumingWithProgress = task.downloadedBytes > 0 ||
              (task.chunks.isNotEmpty && task.chunks.any((c) => c > 0));
          if ((isRetry || isResumingWithProgress) &&
              task.downloadPageUrl != null) {
            try {
              final fresh = await YoutubeService.getFreshStreams(
                  task.downloadPageUrl!,
                  preferredType: task.youtubePreferredType);
              if (fresh != null && fresh['url'] != null) {
                final freshUrl = fresh['url'].toString();
                final freshAudioUrl = fresh['audioUrl']?.toString();
                final videoUrlChanged = freshUrl != task.url;
                final audioUrlChanged = freshAudioUrl != null &&
                    freshAudioUrl != task.mergedAudioUrl;

                // FIX-18: Delete audio sidecars when the audio URL changes so the
                // engine does not resume from corrupt/stale audio bytes.
                if (audioUrlChanged) {
                  for (final p in [
                    '${task.tempFilePath}.audio',
                    '${task.tempFilePath}.audio.dmxstate',
                    '${task.tempFilePath}.audio.journal',
                    '${task.tempFilePath}.audio.itag',
                  ]) {
                    try {
                      final f = File(p);
                      if (await f.exists()) await f.delete();
                    } catch (_) {}
                  }
                }

                task = task.copyWith(
                  url: videoUrlChanged ? freshUrl : task.url,
                  mergedAudioUrl: freshAudioUrl ?? task.mergedAudioUrl,
                  downloadedBytes: videoUrlChanged ? 0 : task.downloadedBytes,
                  chunks: videoUrlChanged
                      ? List<double>.filled(
                          task.threadCount > 0 ? task.threadCount : 1, 0.0)
                      : task.chunks,
                  audioProgress: audioUrlChanged ? 0.0 : task.audioProgress,
                );
              }
            } catch (e) {
              debugPrint('[DMX] Pre-refresh on retry failed: $e');
            }
          }

          Map<String, dynamic>? streamInfo;
          try {
            streamInfo = await YoutubeService.getStreamForVideo(
              videoId,
              task.youtubeQualityPreset,
            );
          } catch (e) {
            debugPrint('[DMX] Pre-download stream resolution failed: $e');
          }

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
            final isVideo = type != 'audio';
            final targetExt = isVideo ? 'mp4' : ext;
            if (type == 'audio') {
              resolvedFileName =
                  title.isNotEmpty ? '$title.$ext' : task.fileName;
            } else {
              final qLabel = streamInfo['quality'] as String? ?? '';
              resolvedFileName = title.isNotEmpty && qLabel.isNotEmpty
                  ? '$title [$qLabel].$targetExt'
                  : (title.isNotEmpty ? '$title.$targetExt' : task.fileName);
            }
            resolvedFileName = safeFileName(resolvedFileName);

            var resolvedLocalPath = task.localFilePath.isNotEmpty
                ? task.localFilePath
                : await getUniqueFilePath(
                    task.savePath,
                    resolvedFileName,
                  );
            if (isVideo &&
                p.extension(resolvedLocalPath).toLowerCase() == '.webm') {
              resolvedLocalPath =
                  '${p.withoutExtension(resolvedLocalPath)}.mp4';
            }
            final resolvedTempPath = task.tempFilePath.isNotEmpty
                ? task.tempFilePath
                : _host.downloadEngine.buildTempFilePath(
                    p.dirname(resolvedLocalPath),
                    resolvedFileName,
                  );

            // FIX-INTEL: Apply recommended headers from site profile
            if (analysis.profile?.needsBrowserUserAgent == true) {
              // Custom UA logic can be injected here or handled in engine
            }

            if (requiresMuxing) {
              final rawVideoSize = streamInfo['videoSize'] as int? ?? 0;
              final rawAudioSize = streamInfo['audioSize'] as int? ?? 0;
              final fallbackSize = streamInfo['size'] as int? ?? 0;

              // FIX YT-3: If sub-sizes are missing, use the combined size
              final videoSize = rawVideoSize > 0
                  ? rawVideoSize
                  : (fallbackSize > rawAudioSize
                      ? fallbackSize - rawAudioSize
                      : 0);
              final audioSize = rawAudioSize > 0 ? rawAudioSize : 0;
              final totalSize = (videoSize + audioSize) > 0
                  ? videoSize + audioSize
                  : fallbackSize;

              // FIX-YT-4: Guard mergedAudioUrl from empty string wipes
              final rawAudioUrl = streamInfo['audioSrc']?.toString();
              final effectiveAudioUrl =
                  (rawAudioUrl != null && rawAudioUrl.isNotEmpty)
                      ? rawAudioUrl
                      : null;

              // FIX-YT-2: Reset audioProgress when audio URL/format changes
              final oldAudioItag = Uri.tryParse(task.mergedAudioUrl ?? '')
                  ?.queryParameters['itag'];
              final newAudioItag = Uri.tryParse(effectiveAudioUrl ?? '')
                  ?.queryParameters['itag'];
              final audioFormatChanged = oldAudioItag != null &&
                  newAudioItag != null &&
                  oldAudioItag != newAudioItag;
              if (audioFormatChanged) {
                for (final p in [
                  '${task.tempFilePath}.audio',
                  '${task.tempFilePath}.audio.dmxstate',
                  '${task.tempFilePath}.audio.journal'
                ]) {
                  try {
                    final f = File(p);
                    if (await f.exists()) await f.delete();
                  } catch (_) {}
                }
              }

              task = task.copyWith(
                url: resolvedUrl,
                mergedAudioUrl: effectiveAudioUrl ?? task.mergedAudioUrl,
                audioProgress: audioFormatChanged ? 0.0 : task.audioProgress,
                audioSize: audioFormatChanged
                    ? audioSize
                    : (audioSize > 0 ? audioSize : task.audioSize),
                fileSize: totalSize,
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
          } else if (streamInfo == null) {
            final uri = Uri.tryParse(task.url);
            if (uri != null &&
                (uri.host.contains('youtube.com') || uri.host == 'youtu.be')) {
              throw Exception(
                  'YouTube stream resolution returned null for page URL');
            }
          } else if (task.url.isNotEmpty &&
              !task.url.contains('youtube.com/')) {
            debugPrint(
              '[DMX] YoutubeService.getStreamForVideo returned null; proceeding with pre-resolved stream URL.',
            );
            return task;
          } else {
            throw Exception('Stream not available');
          }
        }
      } catch (e) {
        if (task.url.isNotEmpty && !task.url.contains('youtube.com/')) {
          debugPrint(
            '[DMX] YoutubeService stream resolution error ($e); proceeding with pre-resolved stream URL.',
          );
          return task;
        } else {
          final isRetryable = isRetryableError(e) ||
              (_isYouTubeTask(task) && _isYouTubeStreamError(e));
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
  Future<bool> _mergeAudioVideo(String taskId, String audioTempPath,
      {int? notificationId}) async {
    var current = _host.findTaskById(taskId);
    if (current == null) return false;

    // FIX-03: Guard against cancelled/dead task before marking merge in progress
    final token = _host.cancelTokens[taskId];
    if (token != null && token.isCancelled) return false;
    if (current.status != DownloadStatus.downloading &&
        current.status != DownloadStatus.merging) {
      return false;
    }

    // FIX-O-01: Check isMergeInProgress flag
    if (current.isMergeInProgress) return false;

    // Mark merge as in progress in the model
    await _host.setTaskState(current.copyWith(isMergeInProgress: true));

    // Re-resolve current task to ensure we have the latest instance
    current = _host.findTaskById(taskId);
    if (current == null) return false;

    try {
      final token = _host.cancelTokens[taskId];
      if (token != null && token.isCancelled) {
        return false;
      }

      // FIX-MERGE-1: Add status guard to _mergeAudioVideo
      if (current.status != DownloadStatus.downloading &&
          current.status != DownloadStatus.merging) {
        debugPrint(
            '[DMX] _mergeAudioVideo skipped: task $taskId status is ${current.status}');
        return false;
      }

      final hasAudio = !current.isTorrent &&
          current.mergedAudioUrl != null &&
          current.mergedAudioUrl!.isNotEmpty;
      if (!hasAudio) return false;

      // FIX-O-02: Set merging status before merge starts
      await _host
          .setTaskState(current.copyWith(status: DownloadStatus.merging));

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
      if (videoOnlyFile.existsSync() &&
          !File(current.localFilePath).existsSync()) {
        debugPrint('[DMX] F4: Restoring video-only file for merge retry');
        await videoOnlyFile.rename(current.localFilePath);
      }

      final videoExt = p.extension(actualVideoPath).isNotEmpty
          ? p.extension(actualVideoPath)
          : '.mp4';

      final mergedPath = actualVideoPath == current.localFilePath
          ? '${current.tempFilePath}.merged$videoExt'
          : '${p.withoutExtension(actualVideoPath)}$videoExt.merged$videoExt';

      final mergedFile = File(mergedPath);
      if (await mergedFile.exists()) {
        final mergedLen = await mergedFile.length();
        if (mergedLen > 1024) {
          debugPrint(
            '[DMX] FIX-S2: Merge output already exists ($mergedLen bytes), skipping FFmpeg execution',
          );
          return true;
        }
      }

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
        debugPrint(
            '[DMX] FIX-B4: _mergeAudioVideo: video file missing: $actualVideoPath');
        await _host.setTaskState(
          current.copyWith(
            statusMessage: DownloadStatusMessages.ffmpegMergeFailed,
            errorMessage: 'Video file missing. Please retry the download.',
          ),
        );
        return false;
      }
      if (!await audioFile.exists()) {
        debugPrint(
            '[DMX] FIX-B4: _mergeAudioVideo: audio file missing: $actualAudioPath');
        await _host.setTaskState(
          current.copyWith(
            statusMessage: DownloadStatusMessages.ffmpegMergeFailed,
            errorMessage: 'Audio file missing. Please retry the download.',
          ),
        );
        return false;
      }

      final videoLen = await actualDownloadedBytes(
        actualVideoPath,
        threadCount: current.threadCount,
      );
      final audioLen = await actualDownloadedBytes(
        actualAudioPath,
        threadCount: current.audioThreadCount,
      );
      debugPrint('[DMX]   Video size: $videoLen bytes');
      debugPrint('[DMX]   Audio size: $audioLen bytes');

      // FIX YT-7: Verify video file size before merge
      if (videoLen == 0) {
        await _host.setTaskState(current.copyWith(
          status: DownloadStatus.failed,
          errorMessage: 'Video file is empty. Cannot merge.',
        ));
        return false;
      }
      // If we know expected video size, verify it's close
      if (current.fileSize > 0 && current.audioSize > 0) {
        final expectedVideo = current.fileSize - current.audioSize;
        if (expectedVideo > 0 && videoLen < (expectedVideo * 0.95).toInt()) {
          await _host.setTaskState(current.copyWith(
            status: DownloadStatus.failed,
            errorMessage:
                'Video file incomplete: $videoLen / $expectedVideo bytes.',
          ));
          return false;
        }
      }

      if (audioLen == 0) {
        debugPrint('[DMX] FIX-B4: audio file empty: $actualAudioPath');
        await _host.setTaskState(
          current.copyWith(
            status: DownloadStatus.failed,
            statusMessage: DownloadStatusMessages.ffmpegMergeFailed,
            errorMessage:
                '${DownloadStatusMessages.ffmpegMergeFailed}Audio file is empty. Please retry the download.',
          ),
        );
        return false;
      }

      // ── FIX-1: Validate audio file integrity before merge ──
      final expectedAudioSize = current.audioSize;
      if (expectedAudioSize > 0 && audioLen < expectedAudioSize) {
        final deficit = expectedAudioSize - audioLen;
        final deficitPct =
            (deficit / expectedAudioSize * 100).toStringAsFixed(1);
        debugPrint(
          '[DMX] FIX-1: audio file incomplete: $audioLen / $expectedAudioSize '
          'bytes ($deficitPct% missing). Failing merge.',
        );
        await _host.setTaskState(
          current.copyWith(
            status: DownloadStatus.failed,
            statusMessage: DownloadStatusMessages.ffmpegMergeFailed,
            errorMessage:
                '${DownloadStatusMessages.ffmpegMergeFailed}Audio file incomplete: '
                '$audioLen / $expectedAudioSize bytes '
                '($deficitPct% missing). Please retry the download.',
          ),
        );
        return false;
      }

      // FIX-10: Validate video file size before merge
      final expectedVideoSize = current.fileSize > 0
          ? (current.fileSize - (current.audioSize > 0 ? current.audioSize : 0))
          : 0;
      if (expectedVideoSize > 0 &&
          videoLen < (expectedVideoSize * 0.95).toInt()) {
        debugPrint(
          '[DMX] FIX-10: video file incomplete: $videoLen / $expectedVideoSize '
          'bytes. Failing merge.',
        );
        await _host.setTaskState(
          current.copyWith(
            status: DownloadStatus.failed,
            statusMessage: DownloadStatusMessages.ffmpegMergeFailed,
            errorMessage:
                '${DownloadStatusMessages.ffmpegMergeFailed}Video file incomplete: '
                '$videoLen / $expectedVideoSize bytes. Please retry the download.',
          ),
        );
        return false;
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
      if (preMergeCheck == null ||
          (preMergeCheck.status != DownloadStatus.downloading &&
              preMergeCheck.status != DownloadStatus.merging)) {
        debugPrint(
            '[DMX] _mergeAudioVideo aborted: task paused/cancelled during merge');
        return false;
      }

      int lastMergeUpdateMs = 0;
      final success = await FFmpegMuxService.mergeVideoAudio(
        actualVideoPath,
        actualAudioPath,
        mergedPath,
        deleteInputsIfTemp: false,
        expectedDuration: expectedDuration,
        onProgress: (double p) async {
          // FIX-12: Throttle merge progress updates to at most twice per second
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - lastMergeUpdateMs < 500) return;
          lastMergeUpdateMs = nowMs;
          final live = _host.findTaskById(taskId);
          if (live != null &&
              (live.status == DownloadStatus.downloading ||
                  live.status == DownloadStatus.merging)) {
            final pct = (p * 100).toStringAsFixed(0);
            await _host.setTaskState(
              live.copyWith(statusMessage: 'Merging… $pct%'),
            );
            if (notificationId != null) {
              _host.notifications.showProgress(
                notificationId: notificationId,
                title: live.fileName,
                progressPercent: 100,
                speed: 'Merging… $pct%',
                eta: '',
                payload: _host.notifications.opaqueHandleFor(live.id),
              );
            }
          }
        },
      );

      final latest = _host.findTaskById(taskId);
      if (latest == null ||
          (latest.status != DownloadStatus.downloading &&
              latest.status != DownloadStatus.merging)) {
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
          // FIX M-3: Require merged file to be at least 90% of expected size
          final expectedMinSize =
              current.fileSize > 0 ? (current.fileSize * 0.9).toInt() : 1024;
          if (mergedLen < expectedMinSize) {
            debugPrint('[DMX] M-3: Merged file too small: '
                '$mergedLen < $expectedMinSize. Deleting.');
            try {
              await mergedFile.delete();
            } catch (_) {}
            return false;
          }
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
          // FIX-B2: Clean up audio sidecars after successful merge
          for (final audioSidecar in [
            '${current.tempFilePath}.audio',
            '${current.tempFilePath}.audio.dmxstate',
            '${current.tempFilePath}.audio.journal',
          ]) {
            try {
              final f = File(audioSidecar);
              if (await f.exists()) await f.delete();
            } catch (e) {
              debugPrint('[DMX] B2 cleanup failed for $audioSidecar: $e');
            }
          }
          // FIX-C1: Guard so cleanup NEVER deletes a path equal to current.localFilePath
          if (current.tempFilePath != current.localFilePath &&
              actualVideoPath != current.localFilePath) {
            try {
              await videoFile.delete();
            } catch (_) {}
            try {
              await File('${current.tempFilePath}.dmxstate').delete();
            } catch (_) {}
            try {
              await File('${current.tempFilePath}.journal').delete();
            } catch (_) {}
          }
        } else {
          throw Exception('Merged output file not found after FFmpeg success');
        }
      } else {
        // FIX-06: Preserve video-only file for merge retry
        final videoOnlyPath =
            '${p.withoutExtension(current.localFilePath)}_video_only'
            '${p.extension(current.localFilePath).isNotEmpty ? p.extension(current.localFilePath) : '.mp4'}';
        try {
          if (videoFile.path != videoOnlyPath) {
            await videoFile.rename(videoOnlyPath);
          }
        } catch (e) {
          debugPrint('[DMX] FIX-06: rename failed: $e');
        }

        await _host.setTaskState(
          current.copyWith(
            status: DownloadStatus.failed,
            // FIX-19: Mark so retry knows to attempt merge-only instead of
            // re-downloading the whole video.
            statusMessage: 'MERGE_FAILED',
            errorMessage:
                '${DownloadStatusMessages.ffmpegMergeFailed} Audio preserved — retry to re-attempt merge.',
            localFilePath: videoOnlyPath,
            // FIX-F1: Preserve audio progress — audio file still exists on disk
            audioProgress: current.audioProgress,
          ),
        );
        return false;
      }
    } finally {
      final latest = _host.findTaskById(taskId);
      if (latest != null) {
        await _host.setTaskState(latest.copyWith(isMergeInProgress: false));
      }
    }

    return true;
  }

  /// FIX-B2: Re-attempt merge only when both video and audio files already exist on disk
  Future<void> retryMergeOnly(DownloadTask task) async {
    final audioTempPath = '${task.tempFilePath}.audio';

    // FIX: Restore video-only file from previous merge failure
    final ext = p.extension(task.localFilePath).isNotEmpty
        ? p.extension(task.localFilePath)
        : '.mp4';
    final videoOnlyPath =
        '${p.withoutExtension(task.localFilePath)}_video_only$ext';
    final videoOnlyFile = File(videoOnlyPath);
    if (videoOnlyFile.existsSync() && !File(task.localFilePath).existsSync()) {
      debugPrint('[DMX] FIX-B1: Restoring video-only file for merge retry');
      await videoOnlyFile.rename(task.localFilePath);
    }

    final videoExists = (await File(task.tempFilePath).exists()) ||
        (await File(task.localFilePath).exists());
    final audioExists = await File(audioTempPath).exists();

    if (!videoExists || !audioExists) {
      debugPrint(
        '[DMX] FIX-N4: Cannot retry merge for ${task.id}: '
        'video=$videoExists, audio=$audioExists',
      );
      await _host.setTaskState(task.copyWith(
        status: DownloadStatus.failed,
        statusMessage: 'MERGE_FAILED',
        errorMessage: 'Missing ${!videoExists ? "video" : "audio"} file. '
            'Please re-download.',
      ));
      return;
    }
    // FIX YT-RT1: Verify the audio file has actual content before
    // attempting the merge. An empty or zero-byte file will produce
    // a corrupt output.
    final audioFileForCheck = File(audioTempPath);
    final audioLen = await audioFileForCheck.length();
    if (audioLen == 0) {
      debugPrint(
        '[DMX] FIX YT-RT1: Audio file is empty for ${task.id}, '
        'cannot merge.',
      );
      await _host.setTaskState(task.copyWith(
        status: DownloadStatus.failed,
        statusMessage: 'MERGE_FAILED',
        errorMessage:
            'Audio file is empty (0 bytes). Please re-download the audio.',
      ));
      return;
    }

    final notificationId = _host.notifications.idFor(task.id);
    await _host.setTaskState(
      task.copyWith(
        status: DownloadStatus.merging,
        statusMessage: 'Merging video and audio...',
        clearError: true,
      ),
    );

    final mergeOk = await _mergeAudioVideo(task.id, audioTempPath);

    if (mergeOk) {
      await _finalizeDownload(task.id, notificationId);
    } else {
      final current = _host.findTaskById(task.id);
      if (current != null) {
        await _host.setTaskState(
          current.copyWith(
            status: DownloadStatus.failed,
            statusMessage: 'MERGE_FAILED', // FIX-B2
            errorMessage:
                '${DownloadStatusMessages.ffmpegMergeFailed} Video saved without audio. Tap retry to re-attempt merge.',
          ),
        );
      }
    }
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
    // FIX F1: Allow merging status as well so YouTube and merge-retry paths finalize cleanly
    if (taskObj.status != DownloadStatus.downloading &&
        taskObj.status != DownloadStatus.merging) {
      return;
    }

    var current = taskObj;

    // Finalize DownloadMetrics
    final metrics = _host.downloadMetrics[taskId];
    if (metrics != null) {
      metrics.markCompleted();
      metrics.totalRetries = _host.retryCounts[taskId] ?? 0;
      metrics.totalBytesDownloaded = current.downloadedBytes;
    }

    final videoOnlyPath = '${p.withoutExtension(current.localFilePath)}'
        '_video_only${p.extension(current.localFilePath)}';
    final videoOnlyFile = File(videoOnlyPath);
    if (videoOnlyFile.existsSync() &&
        !File(current.localFilePath).existsSync()) {
      try {
        await videoOnlyFile.rename(current.localFilePath);
      } catch (_) {}
    }

    // FIX-AUDIT-D3: Verify output file exists before marking completed
    if (!current.isTorrent) {
      final outputFile = File(current.localFilePath);
      if (!await outputFile.exists()) {
        await _host.setTaskState(current.copyWith(
          status: DownloadStatus.failed,
          errorMessage:
              'Output file missing after download/merge. Please retry.',
        ));
        return;
      }
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
        if (!current.hasMergedAudio && actualSize < current.fileSize) {
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

    // FIX-09: Verify merged file size
    if (!current.isTorrent && current.hasMergedAudio && current.fileSize > 0) {
      final finalFile = File(current.localFilePath);
      if (await finalFile.exists()) {
        final actualSize = await finalFile.length();
        final expectedMin = (current.fileSize * 0.95).round(); // 5% tolerance
        if (actualSize < expectedMin) {
          debugPrint(
            '[DMX] FIX-09: Merged file too small: $actualSize < $expectedMin',
          );
          await _host.setTaskState(
            current.copyWith(
              status: DownloadStatus.failed,
              errorMessage:
                  'Merged file size mismatch: expected ~${current.fileSize}, got $actualSize',
            ),
          );
          return;
        }
      }
    }

    await _host.setTaskState(
      current.copyWith(
        clearError: true,
        clearStatusMessage: true,
        status: DownloadStatus.completed,
        fileSize: finalFileSize,
        // FIX-B12: On torrent completion, compute totalFromFiles and use max(totalFromFiles, fileSize)
        downloadedBytes: current.isTorrent
            ? max(
                current.torrentFiles?.fold<int>(
                      0,
                      (s, f) =>
                          s + ((f['downloadedBytes'] as num?)?.toInt() ?? 0),
                    ) ??
                    finalFileSize,
                finalFileSize,
              )
            : (finalFileSize > 0
                ? finalFileSize
                : current.downloadedBytes.clamp(
                    0,
                    finalFileSize > 0 ? finalFileSize : current.downloadedBytes,
                  )),

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

    _sessionCachedTotalSize.remove(taskId);

    if (_host.providerSettingsProvider.vibration) {
      HapticFeedback.vibrate();
    }

    // FIX-INTEL: Record successful outcome
    SiteIntelligenceService().recordOutcome(current.url, true);

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
    // FIX-AUDIT-B2: Clear one-shot flag at start of each download attempt
    _host.resumeRejectionRestarts.remove(task.id);
    final streamThreadCount = runtimeThreadCount;
    final currentTask = _host.findTaskById(task.id);
    if (currentTask == null) return;
    task = currentTask;

    final analysis = SiteIntelligenceService().analyzeUrl(task.url);

    // FIX(B-5): Reset audioProgress to 0.0 when retrying download after failure
    if (task.mergedAudioUrl != null && task.status == DownloadStatus.failed) {
      task = task.copyWith(audioProgress: 0.0);
      await _host.setTaskState(task);
    }

    // FIX H-7: Validate state file integrity before retry loop (A-2)
    final stateFile = File('${task.tempFilePath}.dmxstate');
    if (await stateFile.exists()) {
      try {
        final content = await stateFile.readAsString();
        jsonDecode(content); // throws on corrupt JSON
      } catch (e) {
        debugPrint('[DMX] H-7 FIX: Corrupt .dmxstate detected, deleting.');
        try {
          await stateFile.delete();
        } catch (_) {}
        task = task.copyWith(
          downloadedBytes: 0,
          chunks: List<double>.filled(
              task.threadCount > 0 ? task.threadCount : 1, 0.0),
        );
        await _host.setTaskState(task);
      }
    }

    final maxRetries = _host.providerSettingsProvider.autoRetryEnabled
        ? _host.providerSettingsProvider.maxRetries
        : 0;
    int attempt = 0;

    // Track effective thread count and TTFB in metrics
    _host.downloadMetrics[task.id]?.effectiveThreads = runtimeThreadCount;
    int? ttfbTimestamp;

    final ext = p.extension(task.localFilePath).isNotEmpty
        ? p.extension(task.localFilePath)
        : '.mp4';
    final videoOnlyPath =
        '${p.withoutExtension(task.localFilePath)}_video_only$ext';
    if (File(videoOnlyPath).existsSync() &&
        !File(task.localFilePath).existsSync()) {
      try {
        await File(videoOnlyPath).rename(task.localFilePath);
      } catch (_) {}
    }

    int videoBytesFromDisk;
    final stateFilePath = '${task.tempFilePath}.dmxstate';
    final hasStateFile = await File(stateFilePath).exists();

    if (task.threadCount > 1) {
      // Pre-allocated file length is meaningless without the state file.
      videoBytesFromDisk = hasStateFile
          ? await _readDmxStateBytes(task.tempFilePath,
              threadCount: task.threadCount)
          : 0;
    } else {
      final tempFile = File(task.tempFilePath);
      videoBytesFromDisk = tempFile.existsSync() ? await tempFile.length() : 0;
    }

    // Also fix audio bytes — same pre-allocation issue applies
    int audioBytesFromDisk = 0;
    final audioTempPath = '${task.tempFilePath}.audio';
    if (task.mergedAudioUrl != null && task.mergedAudioUrl!.isNotEmpty) {
      audioBytesFromDisk = await actualDownloadedBytes(
        audioTempPath,
        threadCount: task.audioThreadCount,
      );
    }
    int audioBytesSoFar = audioBytesFromDisk;
    bool audioDone = false; // FIX-02: Track audio stream completion state

    int videoBytesSoFar = videoBytesFromDisk; // FIX-B1
    // FIX-B8: Speed resets on resume — speed is a live metric, not persisted.
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

        // FIX-MERGE-5: Guard pushCombinedProgress against cancelled tasks
        if (base.status != DownloadStatus.downloading) return;

        // FIX YT-S1: When both runtime sizes are unknown, subtract audioSize
        // from fileSize to avoid double-counting the audio contribution.
        final effectiveVideoSize = videoSizeSoFar > 0
            ? videoSizeSoFar
            : (videoTransferSize > 0
                ? videoTransferSize
                : (hasAudio && base.audioSize > 0
                    ? (base.fileSize - base.audioSize).clamp(0, base.fileSize)
                    : base.fileSize));
        final audioContribution = hasAudio
            ? (base.audioSize > 0
                ? base.audioSize
                : (audioBytesSoFar > 0 ? audioBytesSoFar : 0))
            : 0;
        final calculatedTotal = effectiveVideoSize + audioContribution;
        final cachedMax = _sessionCachedTotalSize[task.id] ?? 0;
        final int totalSize;
        if (calculatedTotal > cachedMax) {
          totalSize = calculatedTotal;
          _sessionCachedTotalSize[task.id] = calculatedTotal;
        } else {
          totalSize =
              cachedMax > 0 ? cachedMax : calculatedTotal; // never shrink
        }

        // FIX-09: Clamp numerator totalDownloaded
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

        // FIX YT-S2: When audioSize is unknown, estimate progress from the
        // ratio of audio bytes to the total audio contribution so the bar
        // actually moves during the session.
        final computedAudioProgress = audioDone
            ? 1.0
            : ((hasAudio && base.audioSize > 0)
                ? (audioBytesSoFar / base.audioSize).clamp(0.0, 1.0)
                : (hasAudio && audioBytesSoFar > 0 && audioContribution > 0
                    ? (audioBytesSoFar / audioContribution).clamp(0.0, 0.95)
                    : base.audioProgress));

        final updated = base.copyWith(
          fileName: fileNameOverride ?? base.fileName,
          localFilePath: localFilePathOverride ?? base.localFilePath,
          tempFilePath: tempFilePathOverride ?? base.tempFilePath,
          category: categoryOverride ?? base.category,
          fileSize: totalSize,
          // FIX-B1: Store ONLY video bytes in downloadedBytes for tasks with audio
          downloadedBytes: hasAudio ? videoBytesSoFar : totalDownloaded,
          audioProgress: computedAudioProgress, // FIX-B14
          speed: combinedSpeed,
          eta: calculatedEta,
          clearEta: calculatedEta == null,
          chunks: normalizeChunks(
            chunksOverride ?? base.chunks,
            effectiveVideoSize > 0 ? effectiveVideoSize : totalSize,
            hasAudio ? videoBytesSoFar : totalDownloaded,
          ),
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
          if (base.fileSize == 0 && updated.fileSize > 0) {
            unawaited(_host.setTaskState(updated));
          }
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
        try {
          final videoLen = await actualDownloadedBytes(
            task.tempFilePath,
            threadCount: task.threadCount,
          );
          final audioLen = await actualDownloadedBytes(
            audioTempPath,
            threadCount: task.audioThreadCount,
          );
          // FIX(YT-2): When videoTransferSize is unknown (0), use a minimum threshold
          // to avoid merging incomplete video. Require at least 1KB for video.
          final expectedVideo =
              videoTransferSize > 0 ? videoTransferSize : 1024;
          final expectedAudio = task.audioSize > 0 ? task.audioSize : 1;
          // M4: When the video transfer size is unknown, the 1KB heuristic
          // must not be trusted alone — a pre-allocated temp file reports its
          // full length. Require a .dmxstate so the byte count is proven.
          final videoSizeProven = videoTransferSize > 0 ||
              await File('${task.tempFilePath}.dmxstate').exists();
          if (videoSizeProven &&
              videoLen >= expectedVideo &&
              audioLen >= expectedAudio) {
            debugPrint(
                '[DMX] FIX A-3: Both streams complete. Merge-only path.');
            await _host.setTaskState(task.copyWith(
              statusMessage: DownloadStatusMessages.merging,
            ));
            final merged = await _mergeAudioVideo(task.id, audioTempPath);
            if (merged) {
              await _finalizeDownload(task.id, notificationId);
              return;
            }
          }
        } catch (e) {
          debugPrint('[DMX] Fast-path merge failed with exception: $e');
          await _host.setTaskState(task.copyWith(
            status: DownloadStatus.failed,
            errorMessage: 'Pre-merge stream check failed: $e',
            statusMessage: DownloadStatusMessages.ffmpegMergeFailed,
          ));
          return;
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
            final liveAudioTempPath = audioTempPath;
            final liveAudioSize = liveAudioTask.audioSize;

            final audioFile = File(liveAudioTempPath);
            final audioExists = await audioFile.exists();
            final audioLen = audioExists
                ? await actualDownloadedBytes(
                    liveAudioTempPath,
                    threadCount: liveAudioTask.audioThreadCount,
                  )
                : 0;

            // FIX(YT-4): Only treat audio as complete when:
            // 1. Progress hit 1.0 (exact stream completion), OR
            // 2. Audio exists on disk AND size is known AND bytes >= expected size.
            // When size is unknown (0), we CANNOT declare complete from file alone —
            // rely on audioProgress only. This prevents merging truncated audio.
            final isAudioComplete =
                // Normal: known size and enough bytes on disk
                (audioExists &&
                        audioLen > 0 &&
                        liveAudioSize > 0 &&
                        audioLen >= liveAudioSize) ||
                    // Progress explicitly hit 1.0
                    (audioExists &&
                        audioLen > 0 &&
                        liveAudioTask.audioProgress >= 1.0) ||
                    // Unknown size: trust the .dmxstate or progress >= 0.99
                    (audioExists &&
                        audioLen > 0 &&
                        liveAudioSize <= 0 &&
                        (await File('$liveAudioTempPath.dmxstate').exists() ||
                            liveAudioTask.audioProgress >= 0.99));
            if (isAudioComplete) {
              debugPrint(
                  '[DMX-FIX-05] Audio stream complete ($audioLen / $liveAudioSize bytes)');
            }

            if (isAudioComplete) {
              debugPrint(
                '[DMX] Audio stream already complete ($audioLen bytes, progress: ${liveAudioTask.audioProgress}). Skipping audio re-download.',
              );
              audioDone = true;
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

            final resolvedAudioThreads = liveAudioSize <= 0
                ? 2
                : liveAudioSize < 5 * 1024 * 1024
                    ? 1
                    : liveAudioSize < 50 * 1024 * 1024
                        ? 2
                        : min(4, liveAudioSize > 200 * 1024 * 1024 ? 4 : 3);

            final audioTaskIdx =
                _host.providerTasks.indexWhere((x) => x.id == task.id);
            if (audioTaskIdx != -1) {
              final audioTask = _host.providerTasks[audioTaskIdx];
              // BUG 6 FIX: Preserve recorded audioThreadCount if already set > 0
              final stateThreadCount = audioTask.audioThreadCount > 0
                  ? audioTask.audioThreadCount
                  : resolvedAudioThreads;
              await _host.setTaskState(
                audioTask.copyWith(audioThreadCount: stateThreadCount),
              );
            }

            debugPrint(
                '[DMX] Parallel download: starting audio stream ($resolvedAudioThreads threads).');
            final audioReferer = analysis.profile?.requiresReferer == true
                ? (analysis.profile?.refererValue ??
                    liveAudioTask.mergedAudioUrl)
                : (isYoutube
                    ? (task.downloadPageUrl ?? 'https://www.youtube.com/')
                    : null);

            // FIX-M2: Write itag sidecar at audio download start
            final audioItag = Uri.tryParse(liveAudioTask.mergedAudioUrl ?? '')
                ?.queryParameters['itag'];
            if (audioItag != null) {
              try {
                await File('$liveAudioTempPath.itag').writeAsString(audioItag);
              } catch (_) {}
            }

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
              threadCount: resolvedAudioThreads,
              adaptiveThreads: _host.providerSettingsProvider.adaptiveThreads,
              speedLimitKbps: task.speedLimitKbps,
              onProgress: (progress) {
                if (audioCancelToken.isCancelled || cancelToken.isCancelled) {
                  return;
                }
                final t = _host.findTaskById(task.id);
                if (t == null || t.status != DownloadStatus.downloading) return;
                audioBytesSoFar = progress.downloadedBytes;
                audioSpeedNow = progress.speed;
                // FIX-YT-01: Use engine-reported fileSize; fall back to byte-count heuristic
                final size = t.audioSize > 0 ? t.audioSize : progress.fileSize;

                // FIX YT-01b: Propagate discovered audio size back to task
                if (t.audioSize == 0 && progress.fileSize > 0) {
                  final idx =
                      _host.providerTasks.indexWhere((x) => x.id == task.id);
                  if (idx != -1) {
                    final updated = _host.providerTasks[idx].copyWith(
                      audioSize: progress.fileSize,
                    );
                    _host.providerTasks[idx] = updated;
                    // H3: Persist the discovered audio size immediately so a
                    // crash doesn't leave audioSize == 0 across a restart
                    // (which would corrupt the combined size denominator).
                    unawaited(
                      _host.providerDatabaseService
                          .saveTask(updated)
                          .catchError((_) {}),
                    );
                  }
                }

                final idx = _host.providerTasks.indexWhere(
                  (x) => x.id == task.id,
                );
                if (idx != -1) {
                  _host.providerTasks[idx] = _host.providerTasks[idx].copyWith(
                    audioDownloadedBytes: progress.downloadedBytes,
                    audioSize:
                        size > 0 ? size : _host.providerTasks[idx].audioSize,
                    // FIX-H1: Persist audio fraction on every tick
                    audioProgress: size > 0
                        ? (progress.downloadedBytes / size).clamp(0.0, 1.0)
                        : _host.providerTasks[idx].audioProgress,
                  );
                }
                pushCombinedProgress(
                  statusMessageOverride: progress.statusMessage,
                );
                // FIX-AUDIT-A1: Persist audio progress to sidecar at 2s intervals
                final audioNow = DateTime.now().millisecondsSinceEpoch;
                if (audioNow - _lastAudioStateSaveMs >= 2000) {
                  _lastAudioStateSaveMs = audioNow;
                  unawaited(_persistAudioState(
                      liveAudioTempPath, progress.downloadedBytes, size));
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
              customUserAgent: analysis.profile?.needsBrowserUserAgent == true
                  ? _host.providerSettingsProvider.customUserAgent
                  : _host.providerSettingsProvider.customUserAgent,
              referer: audioReferer,
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

            final liveTask = _host.findTaskById(task.id);
            if (liveTask == null ||
                liveTask.status != DownloadStatus.downloading) {
              debugPrint(
                  '[DMX] runAudio: task no longer downloading, skipping audioProgress update');
              return;
            }

            // Only mark 1.0 when we can confirm completeness
            audioDone = true;
            if (task.audioSize > 0 && downloadedAudioLen < task.audioSize) {
              final frac =
                  (downloadedAudioLen / task.audioSize).clamp(0.0, 1.0);
              final idx =
                  _host.providerTasks.indexWhere((x) => x.id == task.id);
              if (idx != -1) {
                _host.providerTasks[idx] =
                    _host.providerTasks[idx].copyWith(audioProgress: frac);
              }
            } else {
              final idx =
                  _host.providerTasks.indexWhere((x) => x.id == task.id);
              if (idx != -1) {
                _host.providerTasks[idx] =
                    _host.providerTasks[idx].copyWith(audioProgress: 1.0);
              }
            }
            final currentTask = _host.findTaskById(task.id);
            if (currentTask != null &&
                currentTask.downloadedBytes > videoBytesSoFar) {
              videoBytesSoFar = currentTask.downloadedBytes;
            }
            pushCombinedProgress();
          }

          Future<void> runVideo() async {
            final liveVideoTask = _host.findTaskById(task.id);
            final liveHasAudio = liveVideoTask != null &&
                !liveVideoTask.isTorrent &&
                liveVideoTask.mergedAudioUrl != null &&
                liveVideoTask.mergedAudioUrl!.isNotEmpty;
            final int liveVideoTransferSize;
            if (liveHasAudio &&
                liveVideoTask.audioSize > 0 &&
                liveVideoTask.fileSize > liveVideoTask.audioSize) {
              liveVideoTransferSize =
                  liveVideoTask.fileSize - liveVideoTask.audioSize;
            } else if (liveHasAudio &&
                liveVideoTask.audioSize <= 0 &&
                liveVideoTask.fileSize > 0) {
              // FIX-Y3: Audio size unknown — use full fileSize as video size
              liveVideoTransferSize = liveVideoTask.fileSize;
              debugPrint(
                  '[FIX-Y3] Audio size unknown, using full fileSize=$liveVideoTransferSize for video');
            } else {
              liveVideoTransferSize =
                  liveVideoTask?.fileSize ?? videoTransferSize;
            }
            debugPrint('[DMX] Parallel download: starting video stream.');
            final videoReferer = analysis.profile?.requiresReferer == true
                ? (analysis.profile?.refererValue ?? liveVideoTask?.url)
                : (isYoutube ? liveVideoTask?.downloadPageUrl : null);

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
                referer: videoReferer,
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
                    final idx =
                        _host.providerTasks.indexWhere((t) => t.id == task.id);
                    if (idx != -1 &&
                        _host.providerTasks[idx].videoStreamSize == 0) {
                      _host.providerTasks[idx] =
                          _host.providerTasks[idx].copyWith(
                        videoStreamSize: progress.fileSize,
                      ); // FIX-B4
                    }
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
                            preferredType: task.youtubePreferredType,
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
                            final idx = _host.providerTasks
                                .indexWhere((x) => x.id == task.id);
                            if (idx != -1) {
                              _host.providerTasks[idx] =
                                  _host.providerTasks[idx].copyWith(
                                statusMessage:
                                    'Possible throttling — download may be slow. Consider retrying.',
                              );
                            }
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

                  var resolvedFiles =
                      diskVerifiedFiles ?? progress.torrentFiles;
                  // FIX-02: Force selected files to full length when torrent is completed or 100%
                  if (resolvedFiles != null &&
                      (base.status == DownloadStatus.completed ||
                          (base.fileSize > 0 &&
                              progress.downloadedBytes >= base.fileSize))) {
                    resolvedFiles = resolvedFiles.map((f) {
                      final copy = Map<String, dynamic>.from(f);
                      if (copy['selected'] != false) {
                        copy['downloadedBytes'] =
                            (copy['length'] as num?)?.toInt() ??
                                (copy['size'] as num?)?.toInt() ??
                                0;
                        copy['progressEstimated'] = false;
                      }
                      return copy;
                    }).toList();
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
                    torrentFilesOverride: resolvedFiles,
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
                final fresh = await YoutubeService.getFreshStreams(pageUrl,
                    preferredType: task.youtubePreferredType);

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

          try {
            await Future.wait([runVideo(), runAudio()]);
          } on DioException catch (e) {
            if (e.type == DioExceptionType.cancel) {
              return;
            }

            // FIX F-3: If video completed but audio failed, mark for merge retry
            final videoFile = File(task.tempFilePath);
            final audioFile = File('${task.tempFilePath}.audio');
            if (await videoFile.exists() && await audioFile.exists()) {
              final vLen = await actualDownloadedBytes(task.tempFilePath,
                  threadCount: streamThreadCount);
              final aLen = await actualDownloadedBytes(
                  '${task.tempFilePath}.audio',
                  threadCount: task.audioThreadCount);
              if (vLen > 0 && aLen > 0) {
                final current = _host.findTaskById(task.id);
                if (current != null) {
                  await _host.setTaskState(current.copyWith(
                    statusMessage: 'MERGE_FAILED',
                    errorMessage: 'Audio download failed but both files exist. '
                        'Tap retry to attempt merge.',
                  ));
                }
                return; // Don't rethrow — let retry handle merge
              }
            }
            rethrow;
          }

          // FIX-MERGE-3: Add cancellation check between Future.wait and merge in _executeDownload
          if (cancelToken.isCancelled) {
            debugPrint(
                '[DMX] _executeDownload: cancelled after Future.wait, skipping merge');
            return;
          }

          if (hasAudio) {
            // H-3 FIX: Check status before starting merge
            final preMergeCheck = _host.findTaskById(task.id);
            if (preMergeCheck == null ||
                preMergeCheck.status != DownloadStatus.downloading) {
              debugPrint(
                  '[DMX] H-3: Task paused/deleted before merge, skipping merge');
              return;
            }
            // FIX-AUDIT-4: Check merge result. If merge failed, do NOT proceed to finalize.
            // FIX-YT-1: Set merging status before merge in normal download path
            await _host.setTaskState(
                preMergeCheck.copyWith(status: DownloadStatus.merging));
            final mergeOk = await _mergeAudioVideo(task.id, audioTempPath,
                notificationId: notificationId);

            if (!mergeOk) {
              final current = _host.findTaskById(task.id);
              if (current != null &&
                  (current.status == DownloadStatus.downloading ||
                      current.status == DownloadStatus.merging)) {
                await _host.setTaskState(current.copyWith(
                  status: DownloadStatus.failed,
                  statusMessage: 'MERGE_FAILED', // FIX-B2
                  errorMessage:
                      '${DownloadStatusMessages.ffmpegMergeFailed} Video saved without audio. Tap retry to re-attempt merge.',
                ));
              }
              return; // Do NOT call _finalizeDownload
            }

            // FIX-MERGE-6: Add a status re-check after _mergeAudioVideo succeeds but before calling _finalizeDownload
            final postMergeTask = _host.findTaskById(task.id);
            if (postMergeTask == null ||
                (postMergeTask.status != DownloadStatus.downloading &&
                    postMergeTask.status != DownloadStatus.merging)) {
              debugPrint(
                  '[DMX] Skipping finalize: task state changed during merge');
              return;
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
                  final audioChanged = refreshedAudioUrl != null &&
                      refreshedAudioUrl != task.mergedAudioUrl;
                  task = task.copyWith(
                    url: refreshedUrl,
                    mergedAudioUrl: refreshedAudioUrl ?? task.mergedAudioUrl,
                    audioProgress: audioChanged ? 0.0 : task.audioProgress,
                  );
                  final idx = _host.providerTasks.indexWhere(
                    (x) => x.id == task.id,
                  );
                  if (idx != -1) {
                    _host.providerTasks[idx] =
                        _host.providerTasks[idx].copyWith(
                      url: refreshedUrl,
                      mergedAudioUrl: refreshedAudioUrl ?? task.mergedAudioUrl,
                      audioProgress: audioChanged ? 0.0 : task.audioProgress,
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
                  preferredType: task.youtubePreferredType,
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
    } finally {
      await cancelSub.cancel();
    }
  }

  Future<void> _startTaskBody(DownloadTask task) async {
    try {
      // C-1 FIX: Re-check live status before starting
      final liveTask = _host.findTaskById(task.id);
      if (liveTask == null || liveTask.status != DownloadStatus.queued) {
        return; // Task was paused/deleted between pumpQueue filter and here
      }

      // FIX R-2: Re-check YouTube URL freshness right before engine start
      if (task.youtubeQualityPreset != null &&
          task.downloadPageUrl != null &&
          task.downloadPageUrl!.isNotEmpty) {
        try {
          final fresh = await YoutubeService.getFreshStreams(
            task.downloadPageUrl!,
            preferredType: task.youtubePreferredType,
          );
          if (fresh != null &&
              fresh['url'] != null &&
              fresh['url'] != task.url) {
            debugPrint('[DMX] R-2: Refreshing stale YouTube URL before start');
            task = task.copyWith(url: fresh['url'] as String);
            if (fresh['audioUrl'] != null) {
              task = task.copyWith(mergedAudioUrl: fresh['audioUrl']);
            }
            await _host.setTaskState(task);
          }
        } catch (e) {
          debugPrint('[DMX] R-2: Pre-start YouTube refresh failed: $e');
        }
      }

      // FIX-AUDIT-03: Reset one-shot restart flag on every fresh start attempt
      _host.resumeRejectionRestarts.remove(task.id);

      // Clean up stale torrent IDs for tasks that no longer exist
      _host.providerTorrentIds.removeWhere(
        (id, _) => !_host.providerTasks.any((t) => t.id == id),
      );

      // Apply global connection cap override from queue pump (runtime-only, never mutates stored task)
      final runtimeThreadCount =
          _host.effectiveThreadOverrides.remove(task.id) ?? task.threadCount;

      // FIX-H1: Clamp chunk sum to prevent >100% display after redistribution
      try {
        if (task.chunks.isNotEmpty && task.fileSize > 0) {
          final chunkSumBytes = task.chunks.fold<double>(0.0, (s, c) => s + c) *
              (task.fileSize / task.chunks.length);
          if (chunkSumBytes > task.fileSize) {
            final scale = task.fileSize / chunkSumBytes;
            final clampedChunks =
                task.chunks.map((c) => (c * scale).clamp(0.0, 1.0)).toList();
            task = task.copyWith(chunks: clampedChunks);
          }
        }
      } catch (e) {
        debugPrint('[FIX-H1] Chunk clamping error: $e');
      }
      // FIX-9: After any chunk redistribution, keep sum(chunks) aligned with
      // downloadedBytes/fileSize so bar segments stay consistent.
      task = task.copyWith(
        chunks: normalizeChunks(
          task.chunks,
          task.fileSize,
          task.downloadedBytes,
        ),
      );

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
      if (resolved == null) {
        final live = _host.findTaskById(task.id);
        if (live != null && live.status == DownloadStatus.queued) {
          await _host.setTaskState(live.copyWith(
            status: DownloadStatus.failed,
            errorMessage: 'Failed to resolve download stream.',
          ));
        }
        return;
      }
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

      // FIX(04): Skip re-download if both streams complete — jump straight to merge
      if (task.hasMergedAudio && task.tempFilePath.isNotEmpty) {
        final videoFile = File(task.tempFilePath);
        final audioFile = File('${task.tempFilePath}.audio');
        if (await videoFile.exists() && await audioFile.exists()) {
          final vLen = await actualDownloadedBytes(
            task.tempFilePath,
            threadCount: task.threadCount,
          );
          final aLen = await actualDownloadedBytes(
            audioFile.path,
            threadCount: task.audioThreadCount,
          );
          final expectedV = task.fileSize - task.audioSize;
          final expectedA = task.audioSize;
          if (vLen > 0 &&
              aLen > 0 &&
              (expectedV <= 0 || vLen >= expectedV) &&
              (expectedA <= 0 || aLen >= expectedA)) {
            debugPrint(
                '[DMX] FIX(04): Both video and audio streams complete. Skipping download, executing merge.');
            final notificationId = _host.notifications.idFor(task.id);
            await _host.setTaskState(
                task.copyWith(status: DownloadStatus.downloading));
            final merged = await _mergeAudioVideo(task.id, audioFile.path);
            if (merged) {
              await _finalizeDownload(task.id, notificationId);
            } else {
              await _host.setTaskState(task.copyWith(
                status: DownloadStatus.failed,
                errorMessage: 'Merge failed. Tap retry to re-attempt merge.',
              ));
            }
            earlyReturnCompleter.complete();
            _host.activeFutures.remove(task.id);
            _host.cancelTokens.remove(task.id);
            return;
          }
        }
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
              // FIX-D6: If the native torrent handle exists but is in an error/stalled
              // state, remove it and re-add so the retry actually starts fresh.
              final latestStats =
                  _host.providerLatestTorrentStats[existingTorrentId];
              if (latestStats != null &&
                  latestStats.stateLabel.toLowerCase().contains('error')) {
                debugPrint(
                  '[DMX] FIX-D6: Torrent $existingTorrentId is in error state. '
                  'Removing and re-adding for clean retry.',
                );
                try {
                  TorrentService.pauseTorrent(existingTorrentId);
                  TorrentService.removeTorrent(existingTorrentId,
                      deleteFiles: false);
                } catch (_) {}
                _host.providerTorrentIds.remove(task.id);
                torrentId = null;
              } else {
                torrentId = existingTorrentId;
                // Wake the session early so torrentUpdates starts emitting while
                // the engine waits for metadata; a paused torrent can otherwise
                // stay silent and stall the metadata wait.
                TorrentService.resumeTorrent(existingTorrentId);
              }
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

            // C-2 FIX: Set downloading immediately so UI reflects state
            await _host.setTaskState(task.copyWith(
              status: DownloadStatus.downloading,
              statusMessage: 'Connecting to peers...',
            ));
          }
        } catch (e) {
          // FIX(08): Remove native torrent session handle on failure to prevent memory/connection leaks
          final tid = _host.providerTorrentIds[task.id];
          if (tid != null) {
            try {
              TorrentService.pauseTorrent(tid);
              TorrentService.removeTorrent(tid, deleteFiles: false);
            } catch (te) {
              debugPrint('[FIX-08] Failed to cleanup torrent: $te');
            }
            _host.providerTorrentIds.remove(task.id);
          }
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
            final size = (f['length'] as num?)?.toInt() ??
                (f['size'] as num?)?.toInt() ??
                0;
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

      // FIX-INTEL: Re-analyze URL to get site intelligence results
      final analysis = SiteIntelligenceService().analyzeUrl(task.url);
      debugPrint(
          '[DMX] Starting task download: ${analysis.siteType.name} (${analysis.profile?.displayName ?? task.url})');

      // Detect YouTube early so we can skip CDN HEAD probes that trigger 429s.
      final isYoutube = task.downloadPageUrl != null &&
          (task.downloadPageUrl!.contains('youtube.com/') ||
              task.downloadPageUrl!.contains('youtu.be/'));

      if (isYoutube &&
          task.downloadPageUrl != null &&
          realTotalDownloaded > 0) {
        try {
          final fresh = await YoutubeService.getFreshStreams(
              task.downloadPageUrl!,
              preferredType: task.youtubePreferredType);
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
        videoTransferSize = (task.fileSize - task.audioSize).clamp(
          0,
          task.fileSize,
        );
      } else if (hasAudio && task.audioSize <= 0) {
        videoTransferSize = 0;
        debugPrint(
          '[FIX-AUDIT-06] audioSize unknown for ${task.id}, '
          'deferring video size to engine probe',
        );
      } else {
        videoTransferSize = task.fileSize;
      }
      // FIX-01: Clamp videoTransferSize to prevent negative values
      if (videoTransferSize < 0) videoTransferSize = 0;

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

      // FIX-10: Guard against zero/negative video transfer size
      if (videoTransferSize <= 0 && task.fileSize > 0) {
        videoTransferSize = task.fileSize;
      }
      if (videoTransferSize < 0) videoTransferSize = 0; // FIX-10

      // FIX H-1: When new server omits Content-Length AND the resource
      // host or path changed, the old progress cannot be trusted.
      if (videoTransferSize <= 0 && task.downloadedBytes > 0) {
        final cleanUrl = task.url.trim();
        final oldUri = Uri.tryParse(task.url);
        final newUri = Uri.tryParse(cleanUrl);
        final hostChanged = oldUri?.host != newUri?.host;
        final pathChanged = oldUri?.path != newUri?.path;
        if (hostChanged || pathChanged) {
          debugPrint(
            '[DMX] H-1 FIX: Resource changed and size unknown. Resetting progress.',
          );
          task = task.copyWith(
            downloadedBytes: 0,
            chunks: List<double>.filled(
              task.threadCount > 0 ? task.threadCount : 1,
              0.0,
            ),
            clearError: true,
            clearStatusMessage: true,
          );
          await _host.setTaskState(task);
          // Also delete stale state sidecars so old ETag cannot corrupt resume
          for (final p in [
            '${task.tempFilePath}.dmxstate',
            '${task.tempFilePath}.dmxstate.tmp',
          ]) {
            try {
              final f = File(p);
              if (await f.exists()) await f.delete();
            } catch (_) {}
          }
        }
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
          final videoLen = await actualDownloadedBytes(
            task.tempFilePath,
            threadCount: task.threadCount,
          );
          final audioLen = await actualDownloadedBytes(
            audioFile.path,
            threadCount: task.audioThreadCount,
          );

          if (videoLen > 1024 && audioLen > 1024) {
            // FIX(YT2): Don't treat unknown-size audio as complete
            final audioComplete = task.audioProgress >= 1.0 ||
                (audioLen > 0 &&
                    task.audioSize > 0 &&
                    audioLen >= task.audioSize);

            if (videoTransferSize <= 0) {
              debugPrint(
                '[DMX] B5: Skipping merge-only path — video size unknown. '
                'Falling through to normal download path.',
              );
            } else {
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
                    errorMessage: DownloadStatusMessages.ffmpegMergeFailed,
                  ));
                }
                return;
              }
            }
          }
        }
      }
      // ═══ END FIX YT-2/YT-6 ═══

      // H-1 FIX: Check if task was paused/deleted during async gap
      final preStartCheck = _host.findTaskById(task.id);
      if (preStartCheck == null ||
          preStartCheck.status != DownloadStatus.downloading) {
        return;
      }
      // FIX H-3: Zero downloadedBytes in task model immediately when supportsResume is false
      if (!task.isTorrent && !task.supportsResume && task.downloadedBytes > 0) {
        task = task.copyWith(
          downloadedBytes: 0,
          chunks: List<double>.filled(
            task.threadCount > 0 ? task.threadCount : 1,
            0.0,
          ),
        );
        await _host.setTaskState(task);
        // FIX H-S1: Delete the stale temp file and state sidecars so the
        // engine starts fresh instead of reconciling against old bytes.
        for (final p in [
          task.tempFilePath,
          '${task.tempFilePath}.dmxstate',
          '${task.tempFilePath}.dmxstate.tmp',
          '${task.tempFilePath}.journal',
        ]) {
          try {
            final f = File(p);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }

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
        // FIX-MERGE-2: Remove the duplicate merge/finalize from the .then() callback
        debugPrint('[DMX] _executeDownload completed for ${task.id}');
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

        if (task.isTorrent) {
          final tid = _host.providerTorrentIds[task.id];
          if (tid != null && TorrentService.isTorrentAlive(tid)) {
            try {
              TorrentService.pauseTorrent(tid);
              TorrentService.removeTorrent(tid, deleteFiles: false);
            } catch (_) {}
            _host.providerTorrentIds.remove(task.id);
          }
        }

        if (!cancelToken.isCancelled) {
          try {
            cancelToken.cancel('Task failed, cleaning up in-flight requests');
          } catch (_) {}
        }

        await _host.flushPendingProgress(task.id);
        final current = _host.findTaskById(task.id);
        if (current == null) return;
        // FIX-04: Do not overwrite user-paused or completed status on error catch
        if (current.status == DownloadStatus.paused ||
            current.status == DownloadStatus.completed) {
          return;
        }

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

        final isRetryable = isRetryableError(realError) ||
            (_isYouTubeTask(task) && _isYouTubeStreamError(realError));
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

        // FIX-INTEL: Record failure outcome
        SiteIntelligenceService().recordOutcome(task.url, false);

        // FIX-B5: Delete state sidecars on permanent failure but preserve .dmxpart data
        for (final path in [
          '${current.tempFilePath}.dmxstate',
          '${current.tempFilePath}.journal',
          '${current.tempFilePath}.audio.dmxstate',
        ]) {
          try {
            final f = File(path);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }

        // FIX F6: Preserve partial temp files if failure is retryable so manual retry can resume
        try {
          await _host.cleanupPartFiles(current, preserveParts: isRetryable);
          await cleanupTempFiles(current, preserveParts: isRetryable);
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
        if (!earlyReturnCompleter.isCompleted) {
          earlyReturnCompleter.complete();
        }
      });
      _host.activeFutures[task.id] = downloadFuture;
    } catch (e, st) {
      // FIX-1: _startTaskBody must never leave a task stuck in queued or leak
      // the _startingTaskIds entry. Any unhandled exception (disk full, resolve
      // failure) marks the task failed and frees the concurrency slot.
      debugPrint('[DMX] _startTaskBody unexpected error for ${task.id}: $e');
      debugPrint('[DMX] _startTaskBody stack: $st');
      final live = _host.findTaskById(task.id);
      if (live != null && live.status == DownloadStatus.queued) {
        await _host.setTaskState(live.copyWith(
          status: DownloadStatus.failed,
          errorMessage: 'Start failed: $e',
          speed: 0,
          clearEta: true,
        ));
      }
      _host.pumpQueue();
    }
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
        (msg.contains('not found') &&
            !msg.contains('stream') &&
            !msg.contains('youtube'))) {
      return false;
    }
    // FIX-10: YouTube stream expiry and bot detection are transient
    if (msg.contains('html_instead_of_media') ||
        msg.contains('html instead of media') ||
        msg.contains('sign in to confirm') ||
        msg.contains('bot')) {
      return true;
    }
    if (error is DioException) {
      if (error.type == DioExceptionType.cancel) {
        return false;
      }
      final statusCode = error.response?.statusCode;
      if (statusCode != null) {
        if (statusCode == 400 ||
            statusCode == 401 ||
            statusCode == 403 ||
            statusCode == 404 ||
            statusCode == 410 ||
            statusCode == 416) {
          // A generic 403/410 (auth/access denied) must NOT be retried. The
          // YouTube-only case (expired stream URL) is handled by
          // _isYouTubeStreamError at the task-aware call sites below.
          return false;
        }
      }
    }

    return true;
  }

  /// True for 403/410 HTTP errors that usually mean an expired YouTube
  /// stream URL or a bot-check page, or backend cold-start errors.
  /// Only meaningful for YouTube tasks.
  static bool _isYouTubeStreamError(Object error) {
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode == 403 ||
          statusCode == 410 ||
          statusCode == 404 ||
          (statusCode != null && statusCode >= 500)) {
        return true;
      }
    }
    final msg = error.toString().toLowerCase();
    return msg.contains('html_instead_of_media') ||
        msg.contains('html instead of media') ||
        msg.contains('sign in to confirm') ||
        msg.contains('bot') ||
        msg.contains('stream') ||
        msg.contains('backend') ||
        msg.contains('cannot reach') ||
        msg.contains('failed to load youtube');
  }

  /// Whether [task] belongs to a YouTube download. Used to scope the
  /// expired-stream retry (403/410) to YouTube tasks only.
  static bool _isYouTubeTask(DownloadTask task) {
    if (task.youtubeQualityPreset != null) return true;
    final url = '${task.url} ${task.downloadPageUrl ?? ''}'.toLowerCase();
    return url.contains('youtube.com') || url.contains('youtu.be');
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

  /// Cleans up temporary download artifacts (.dmxpart, .dmxstate, .journal, .audio)
  /// for a task when a non-retryable failure occurs.
  Future<void> cleanupTempFiles(
    DownloadTask task, {
    bool preserveParts = false,
  }) async {
    final List<File> sidecars = [
      File('${task.tempFilePath}.journal'), // always safe to delete
      File('${task.tempFilePath}.audio.journal'), // M1: always safe to delete
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
        File('${task.tempFilePath}.audio.journal'), // M1: always safe to delete
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
    return actualDownloadedBytes(tempFilePath, threadCount: threadCount);
  }

  /// FIX-9: Normalizes a chunk list so its sum equals `downloadedBytes /
  /// fileSize * chunks.length`. Adaptive thread redistribution can otherwise
  /// drift the per-chunk percentages, producing inconsistent bar segments.
  // FIX-B6: Normalize chunks without distorting 100%-complete chunks
  static List<double> normalizeChunks(
    List<double> chunks,
    int fileSize,
    int downloadedBytes,
  ) {
    if (fileSize <= 0 || chunks.isEmpty) return chunks;
    // FIX-09: Sanitize NaN/Infinity chunks before normalizing.
    final safeChunks = chunks.map((c) {
      if (c.isNaN || c.isInfinite) return 0.0;
      return c.clamp(0.0, 1.0);
    }).toList();
    final targetSum =
        (downloadedBytes / fileSize).clamp(0.0, 1.0) * safeChunks.length;
    // Lock completed chunks
    final locked = safeChunks.map((c) => c >= 0.999 ? 1.0 : c).toList();
    final lockedSum =
        locked.where((c) => c >= 1.0).fold<double>(0.0, (s, c) => s + c);
    final remainingTarget =
        (targetSum - lockedSum).clamp(0.0, locked.length - lockedSum);
    final unlocked = locked.where((c) => c < 1.0).toList();
    final unlockedSum = unlocked.fold<double>(0.0, (s, c) => s + c);
    if (unlockedSum <= 0) return locked;
    final scale = remainingTarget / unlockedSum;
    int ui = 0;
    return locked.map((c) {
      if (c >= 1.0) return 1.0;
      final scaled = (unlocked[ui++] * scale).clamp(0.0, 1.0);
      return scaled;
    }).toList();
  }

  // FIX-AUDIT-A1: Audio state persistence helper
  int _lastAudioStateSaveMs = 0;

  Future<void> _persistAudioState(
      String audioPath, int downloaded, int totalSize) async {
    try {
      final statePath = '$audioPath.dmxstate';
      final state = {
        'version': 3,
        'v': 3,
        'totalSize': totalSize,
        'threadCount': 1,
        'progress': [downloaded],
        'status': 'active',
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'chunks': [
          {
            'start': 0,
            'end': totalSize > 0 ? totalSize - 1 : -1,
            'downloaded': downloaded
          }
        ],
      };
      final tmpPath = '$statePath.tmp';
      final tmp = File(tmpPath);
      await tmp.writeAsString(jsonEncode(state), flush: true);
      await tmp.rename(statePath);
    } catch (_) {}
  }
}
