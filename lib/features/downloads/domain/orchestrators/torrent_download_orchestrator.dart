import 'dart:async';
import 'package:dio/dio.dart';
import 'package:dmx/core/domain/engine_types.dart';
import 'package:dmx/core/services/diagnostic_service.dart';
import 'package:dmx/core/services/dio_client_pool.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:dmx/core/services/torrent_service.dart';

/// Orchestrates Torrent downloads, delegating to the canonical TorrentDownloadHandler.
/// Moved to feature domain layer for Clean Architecture.
class TorrentDownloadOrchestrator {
  final DioClientPool _dioPool;
  final TorrentDownloadHandler _handler;

  TorrentDownloadOrchestrator(this._dioPool, [TorrentDownloadHandler? handler])
      : _handler = handler ?? TorrentDownloadHandler();

  Future<void> download({
    required String url,
    required String currentLocalFilePath,
    required int knownFileSize,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int? torrentId,
    bool isRetry = false,
    int? metadataTimeoutSeconds,
    String? effectiveTaskId,
  }) async {
    final resolvedTaskId = effectiveTaskId ?? 'torrent_${torrentId ?? url.hashCode}';
    int? activeTorrentId = torrentId;
    DownloadProgress? lastEmittedProgress;

    void wrappedOnProgress(DownloadProgress p) {
      if (p.torrentId != null && p.torrentId! >= 0) {
        activeTorrentId = p.torrentId;
      }
      lastEmittedProgress = p;
      onProgress(p);
    }

    StreamSubscription? alertSub;
    try {
      alertSub = TorrentService.alertUpdates.listen((TorrentAlertEvent alert) {
        if (activeTorrentId != null && alert.torrentId == activeTorrentId) {
          if (alert.type == 19 || alert.category == 'fastresumeRejected') {
            // Transition task to CycleState.verifying and emit status message. Do NOT mark as failed.
            wrappedOnProgress(DownloadProgress(
              downloadedBytes: lastEmittedProgress?.downloadedBytes ?? 0,
              fileSize: lastEmittedProgress?.fileSize ?? (knownFileSize > 0 ? knownFileSize : 0),
              speed: 0,
              eta: null,
              fileName: lastEmittedProgress?.fileName,
              torrentFiles: lastEmittedProgress?.torrentFiles,
              statusMessage: 'Re-verifying file integrity (resume data rejected by engine)',
              cycleState: CycleState.verifying,
              torrentId: activeTorrentId,
            ));
          } else if (alert.type == 31 || alert.category == 'saveResumeDataFailed') {
            DiagnosticService.instance.recordTelemetryAlert(
              'resume_data_missing',
              taskId: resolvedTaskId,
              details: alert.message,
            );
            Future.delayed(const Duration(seconds: 2), () {
              try {
                if (activeTorrentId != null && activeTorrentId! >= 0) {
                  TorrentService.saveResumeData(activeTorrentId!);
                }
              } catch (_) {}
            });
          }
        }
      });

      return await _handler.handleTorrentDownload(
        taskId: resolvedTaskId,
        url: url,
        currentLocalFilePath: currentLocalFilePath,
        knownFileSize: knownFileSize,
        cancelToken: cancelToken,
        onProgress: wrappedOnProgress,
        clientBuilder: (u) => _dioPool.acquireClient(url: u),
        clientReleaser: (client) => _dioPool.releaseClient(client),
        getTorrentFiles: getTorrentFiles,
        torrentId: torrentId,
        isRetry: isRetry,
      );
    } finally {
      await alertSub?.cancel();
    }
  }
}

