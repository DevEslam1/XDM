import 'package:dio/dio.dart';
import '../../../features/downloads/models/download_task.dart';
import '../ffmpeg_mux_service.dart';

/// Handles YouTube/media stream downloads and FFmpeg audio/video muxing.
class MediaDownloadEngine {
  final FFmpegMuxService muxService;

  MediaDownloadEngine({FFmpegMuxService? muxService})
      : muxService = muxService ?? FFmpegMuxService();

  Future<void> download({
    required DownloadTask task,
    required CancelToken cancelToken,
    required void Function(double progress, int downloadedBytes, int speedBps)
        onProgress,
  }) async {
    throw UnimplementedError(
      'MediaDownloadEngine.download is not yet implemented. '
      'Use DownloadEngine for HTTP downloads with FFmpegMuxService for merging.',
    );
  }
}
