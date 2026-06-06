enum DetectedMediaKind { video, audio, image, document, archive, executable, torrent, magnet, unknown }

class DetectedMedia {
  final DetectedMediaKind kind;
  final String url;
  final String? suggestedFileName;

  const DetectedMedia({
    required this.kind,
    required this.url,
    this.suggestedFileName,
  });
}

class BrowserDetector {
  static const Map<String, DetectedMediaKind> _extensionMap = {
    '.mp4': DetectedMediaKind.video,
    '.mkv': DetectedMediaKind.video,
    '.avi': DetectedMediaKind.video,
    '.mov': DetectedMediaKind.video,
    '.webm': DetectedMediaKind.video,
    '.flv': DetectedMediaKind.video,
    '.mp3': DetectedMediaKind.audio,
    '.wav': DetectedMediaKind.audio,
    '.flac': DetectedMediaKind.audio,
    '.m4a': DetectedMediaKind.audio,
    '.ogg': DetectedMediaKind.audio,
    '.aac': DetectedMediaKind.audio,
    '.jpg': DetectedMediaKind.image,
    '.jpeg': DetectedMediaKind.image,
    '.png': DetectedMediaKind.image,
    '.gif': DetectedMediaKind.image,
    '.webp': DetectedMediaKind.image,
    '.bmp': DetectedMediaKind.image,
    '.svg': DetectedMediaKind.image,
    '.pdf': DetectedMediaKind.document,
    '.docx': DetectedMediaKind.document,
    '.doc': DetectedMediaKind.document,
    '.xlsx': DetectedMediaKind.document,
    '.xls': DetectedMediaKind.document,
    '.pptx': DetectedMediaKind.document,
    '.ppt': DetectedMediaKind.document,
    '.txt': DetectedMediaKind.document,
    '.zip': DetectedMediaKind.archive,
    '.rar': DetectedMediaKind.archive,
    '.7z': DetectedMediaKind.archive,
    '.tar': DetectedMediaKind.archive,
    '.gz': DetectedMediaKind.archive,
    '.iso': DetectedMediaKind.archive,
    '.apk': DetectedMediaKind.executable,
    '.exe': DetectedMediaKind.executable,
    '.dmg': DetectedMediaKind.executable,
    '.pkg': DetectedMediaKind.executable,
    '.torrent': DetectedMediaKind.torrent,
  };

  static DetectedMedia? detect(String url) {
    final lower = url.toLowerCase();
    if (lower.startsWith('magnet:?')) {
      return DetectedMedia(kind: DetectedMediaKind.magnet, url: url);
    }
    final cleanUrl = lower.split('?').first.split('#').first;
    for (final entry in _extensionMap.entries) {
      if (cleanUrl.endsWith(entry.key) ||
          lower.contains('${entry.key}?') ||
          lower.contains('${entry.key}&')) {
        return DetectedMedia(
          kind: entry.value,
          url: url,
          suggestedFileName: _suggestName(url, entry.key),
        );
      }
    }
    if (lower.contains('/download') ||
        lower.contains('download_file') ||
        lower.contains('attachment')) {
      return DetectedMedia(
        kind: DetectedMediaKind.unknown,
        url: url,
        suggestedFileName: _suggestName(url, ''),
      );
    }
    return null;
  }

  static bool isAutoDownloadable(String url) {
    return detect(url) != null;
  }

  static String _suggestName(String url, String ext) {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments
          .where((s) => s.trim().isNotEmpty)
          .toList();
      if (segments.isEmpty) return 'download${ext.isEmpty ? '' : ext}';
      var last = segments.last;
      if (!last.toLowerCase().endsWith(ext) && ext.isNotEmpty) {
        last = '$last$ext';
      }
      return last;
    } catch (_) {
      return 'download${ext.isEmpty ? '' : ext}';
    }
  }
}
