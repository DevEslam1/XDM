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
    throw UnimplementedError(
      'TorrentDownloadEngine.download is not yet implemented. '
      'Torrent downloads are handled via TorrentService FFI in DownloadEngine._handleTorrentDownload.',
    );
  }
}
