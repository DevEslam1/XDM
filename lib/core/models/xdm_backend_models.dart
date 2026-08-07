/// Backend API exception with detailed error messages.
class ApiException implements Exception {
  final int statusCode;
  final String body;
  ApiException(this.statusCode, this.body);

  String get userMessage {
    if (body.contains('Sign in to confirm')) {
      return 'YouTube requires sign-in. Try again later.';
    }
    if (body.contains('age')) return 'This video is age-restricted.';
    if (body.contains('geo')) {
      return 'This video is not available in your region.';
    }
    if (body.contains('No streams')) return 'No downloadable streams found.';
    return 'Error $statusCode: $body';
  }

  @override
  String toString() => 'ApiException($statusCode): $userMessage';
}

/// Extracted video stream info from the backend (`GET /api/streams`).
class VideoStreams {
  final String url;
  final String title;
  final String? id; // Present for YouTube, may be absent for other platforms
  final List<StreamEntry> streams;

  VideoStreams({
    required this.url,
    required this.title,
    this.id,
    required this.streams,
  });

  VideoStreams.fromJson(Map<String, dynamic> json)
      : url = json['url']?.toString() ?? '',
        title = json['title']?.toString() ?? '',
        id = json['id']?.toString(),
        streams = ((json['streams'] as List?) ?? [])
            .map((e) =>
                StreamEntry.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        if (id != null) 'id': id,
        'streams': streams.map((e) => e.toJson()).toList(),
      };
}

/// Single video/audio stream entry.
class StreamEntry {
  final String type;
  final String quality;
  final String label;
  final String src;
  final String ext;
  final String formatId;
  final String manifestType;
  final String? audioSrc;
  final String? videoId;
  final int videoSize;
  final int audioSize;
  final int size;

  StreamEntry({
    required this.type,
    required this.quality,
    required this.label,
    required this.src,
    this.audioSrc,
    required this.videoSize,
    required this.audioSize,
    required this.size,
    required this.ext,
    required this.formatId,
    this.videoId,
    required this.manifestType,
  });

  StreamEntry.fromJson(Map<String, dynamic> json)
      : type = json['type']?.toString() ?? '',
        quality = json['quality']?.toString() ?? '',
        label = json['label']?.toString() ?? '',
        src = json['src']?.toString() ?? '',
        audioSrc = json['audioSrc']?.toString(),
        videoSize = _toInt(json['videoSize']),
        audioSize = _toInt(json['audioSize']),
        size = _toInt(json['size']),
        ext = json['ext']?.toString() ?? 'mp4',
        formatId =
            json['format_id']?.toString() ?? json['formatId']?.toString() ?? '',
        videoId = json['videoId']?.toString(),
        manifestType = json['manifestType']?.toString() ?? '';

  static int _toInt(dynamic val) {
    if (val is num) return val.toInt();
    if (val != null) return int.tryParse(val.toString()) ?? 0;
    return 0;
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        'quality': quality,
        'label': label,
        'src': src,
        if (audioSrc != null) 'audioSrc': audioSrc,
        'videoSize': videoSize,
        'audioSize': audioSize,
        'size': size,
        'ext': ext,
        'format_id': formatId,
        if (videoId != null) 'videoId': videoId,
        'manifestType': manifestType,
      };

  bool get isPlayable => type == 'combined' || type == 'muxed';
  bool get needsMuxing => type == 'video_only';
}

/// Playlist metadata (`GET /api/playlist`).
class PlaylistInfo {
  final String title;
  final String author;
  final int videoCount;
  final String? note;
  final List<PlaylistVideo> videos;

  PlaylistInfo({
    required this.title,
    required this.author,
    required this.videoCount,
    this.note,
    required this.videos,
  });

  PlaylistInfo.fromJson(Map<String, dynamic> json)
      : title = (json['info'] is Map
                ? (json['info'] as Map)['title']?.toString()
                : null) ??
            json['title']?.toString() ??
            '',
        author = (json['info'] is Map
                ? (json['info'] as Map)['author']?.toString()
                : null) ??
            json['author']?.toString() ??
            '',
        videoCount = _toInt(json['info'] is Map
            ? (json['info'] as Map)['videoCount']
            : json['videoCount']),
        note = json['note']?.toString(),
        videos = ((json['videos'] as List?) ?? [])
            .map((e) =>
                PlaylistVideo.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();

  static int _toInt(dynamic val) {
    if (val is num) return val.toInt();
    if (val != null) return int.tryParse(val.toString()) ?? 0;
    return 0;
  }

  Map<String, dynamic> toJson() => {
        'info': {
          'title': title,
          'author': author,
          'videoCount': videoCount,
        },
        if (note != null) 'note': note,
        'videos': videos.map((e) => e.toJson()).toList(),
      };
}

/// Single item in a playlist.
class PlaylistVideo {
  final String id;
  final String title;
  final String author;
  final String thumbnailUrl;
  final String url;
  final int duration;
  final bool selected;

  PlaylistVideo({
    required this.id,
    required this.title,
    required this.author,
    required this.thumbnailUrl,
    required this.url,
    required this.duration,
    this.selected = true,
  });

  PlaylistVideo.fromJson(Map<String, dynamic> json)
      : id = json['id']?.toString() ?? '',
        title = json['title']?.toString() ?? '',
        author = json['author']?.toString() ?? '',
        thumbnailUrl = json['thumbnailUrl']?.toString() ?? '',
        url = json['url']?.toString() ?? '',
        duration = _toInt(json['duration']),
        selected = json['selected'] is bool ? json['selected'] as bool : true;

  static int _toInt(dynamic val) {
    if (val is num) return val.toInt();
    if (val != null) return int.tryParse(val.toString()) ?? 0;
    return 0;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'thumbnailUrl': thumbnailUrl,
        'url': url,
        'duration': duration,
        'selected': selected,
      };
}

/// Search result from backend search (`GET /api/search`).
class SearchResult {
  final String id;
  final String title;
  final String author;
  final String thumbnailUrl;
  final String url;
  final int duration;

  SearchResult({
    required this.id,
    required this.title,
    required this.author,
    required this.thumbnailUrl,
    required this.url,
    required this.duration,
  });

  SearchResult.fromJson(Map<String, dynamic> json)
      : id = json['id']?.toString() ?? '',
        title = json['title']?.toString() ?? '',
        author = json['author']?.toString() ?? '',
        thumbnailUrl = json['thumbnailUrl']?.toString() ?? '',
        url = json['url']?.toString() ?? '',
        duration = _toInt(json['duration']);

  static int _toInt(dynamic val) {
    if (val is num) return val.toInt();
    if (val != null) return int.tryParse(val.toString()) ?? 0;
    return 0;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'thumbnailUrl': thumbnailUrl,
        'url': url,
        'duration': duration,
      };
}
