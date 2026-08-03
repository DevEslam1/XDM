import 'package:dio/dio.dart';
import '../../../features/downloads/models/download_task.dart';

/// Handles torrent downloads via libtorrent.
class TorrentDownloadEngine {
  Future<void> download({
    required DownloadTask task,
    required CancelToken cancelToken,
    required void Function(double progress, int downloadedBytes, int speedBps)
        onProgress,
  }) async {
    // Engine execution stub — wrapped by orchestrator DownloadEngine
  }
}
