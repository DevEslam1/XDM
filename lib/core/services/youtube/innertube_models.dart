/// Data models for InnerTube stream responses.
library;

/// Represents a single stream (video, audio, muxed, or combined).
class InnerTubeStream {
  /// Direct download URL for this stream.
  final String url;

  /// Audio URL for combined type (video + separate audio download).
  final String? audioUrl;

  /// Human-readable label, e.g. "720p (Video Only)" or "128kbps Audio".
  final String label;

  /// Total size in bytes. For combined, this is video + audio size.
  final int size;

  /// Audio size in bytes (only for combined type).
  final int? audioSize;

  /// File extension: 'mp4' or 'webm'.
  final String ext;

  /// Video title.
  final String title;

  /// Quality string: "720p", "128kbps", etc.
  final String quality;

  /// Stream type: 'muxed', 'video_only', 'audio', 'combined'.
  final String type;

  /// YouTube itag identifier for format matching on refresh.
  final int? itag;

  /// Video height in pixels (null for audio-only).
  final int? height;

  /// Full MIME type, e.g. "video/mp4; codecs=\"avc1.64001F, mp4a.40.2\"".
  final String? mimeType;

  /// Unix timestamp (seconds) when the URL expires.
  final int? expireTimestamp;

  const InnerTubeStream({
    required this.url,
    this.audioUrl,
    required this.label,
    required this.size,
    this.audioSize,
    required this.ext,
    required this.title,
    required this.quality,
    required this.type,
    this.itag,
    this.height,
    this.mimeType,
    this.expireTimestamp,
  });

  /// Whether this stream URL is likely expired based on [expireTimestamp].
  bool get isExpired {
    if (expireTimestamp == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= expireTimestamp!;
  }

  /// Converts to the Map format expected by existing UI/download code.
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'src': url,
      'label': label,
      'size': size,
      'ext': ext,
      'title': title,
      'quality': quality,
      'type': type,
    };
    if (audioUrl != null) map['audioSrc'] = audioUrl;
    if (audioSize != null) map['audioSize'] = audioSize;
    return map;
  }

  @override
  String toString() =>
      'InnerTubeStream(type=$type, quality=$quality, size=$size, itag=$itag)';
}

/// Playlist metadata returned by InnerTube browse endpoint.
class InnerTubePlaylist {
  final String id;
  final String title;
  final String author;
  final int videoCount;
  final String thumbnailUrl;
  final List<InnerTubePlaylistVideo> videos;

  const InnerTubePlaylist({
    required this.id,
    required this.title,
    required this.author,
    required this.videoCount,
    required this.thumbnailUrl,
    required this.videos,
  });

  /// Converts to the Map format used by existing playlist UI code.
  Map<String, dynamic> toDetailsMap() {
    return {
      'info': {
        'id': id,
        'title': title,
        'author': author,
        'videoCount': videoCount,
        'thumbnailUrl': thumbnailUrl,
      },
      'videos': videos.map((v) => v.toMap()).toList(),
    };
  }
}

/// A single video entry within a playlist.
class InnerTubePlaylistVideo {
  final String id;
  final String title;
  final String author;
  final int duration;
  final String thumbnailUrl;

  const InnerTubePlaylistVideo({
    required this.id,
    required this.title,
    required this.author,
    required this.duration,
    required this.thumbnailUrl,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'author': author,
    'duration': duration,
    'thumbnailUrl': thumbnailUrl,
    'selected': true,
  };
}
