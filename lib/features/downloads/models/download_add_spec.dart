/// A compact description for a single download item that can be added in bulk.
class DownloadAddSpec {
  final String name;
  final String url;
  final int size;
  final String category;
  final String savePath;
  final int? threadCount;
  final DateTime? scheduledAt;
  final List<Map<String, dynamic>>? torrentFiles;
  final String? downloadPageUrl;
  final String? mergedAudioUrl;
  final int audioSize;
  final String? youtubeQualityPreset;
  final int? torrentId;
  final bool isAppUpdate;
  final String? playlistId;
  final String? playlistTitle;
  final String? thumbnailUrl;

  const DownloadAddSpec({
    required this.name,
    required this.url,
    required this.size,
    required this.category,
    required this.savePath,
    this.threadCount,
    this.scheduledAt,
    this.torrentFiles,
    this.downloadPageUrl,
    this.mergedAudioUrl,
    this.audioSize = 0,
    this.youtubeQualityPreset,
    this.torrentId,
    this.isAppUpdate = false,
    this.playlistId,
    this.playlistTitle,
    this.thumbnailUrl,
  });
}
