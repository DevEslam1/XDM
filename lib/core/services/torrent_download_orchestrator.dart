import 'package:dio/dio.dart';
import 'package:dmx/core/services/dio_client_pool.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';

/// Orchestrates Torrent downloads, delegating to the canonical TorrentDownloadHandler.
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
    String? taskId,
  }) async {
    return _handler.handleTorrentDownload(
      taskId: taskId ?? 'torrent_${torrentId ?? url.hashCode}',
      url: url,
      currentLocalFilePath: currentLocalFilePath,
      knownFileSize: knownFileSize,
      cancelToken: cancelToken,
      onProgress: onProgress,
      clientBuilder: (u) => _dioPool.acquireClient(url: u),
      clientReleaser: (client) => _dioPool.releaseClient(client),
      getTorrentFiles: getTorrentFiles,
      torrentId: torrentId,
      isRetry: isRetry,
    );
  }
}
