import 'package:logging/logging.dart';
import '../../../core/services/site_intelligence/site_intelligence_service.dart';

enum DetectedMediaKind {
  video,
  audio,
  image,
  document,
  archive,
  executable,
  torrent,
  magnet,
  // Fix #16: Streaming manifests (HLS/DASH) should be played in the browser,
  // not downloaded. They are classified separately from video files.
  stream,
  unknown
}

enum DetectionConfidence { high, low }

class DetectedMedia {
  final DetectedMediaKind kind;
  final String url;
  final String? suggestedFileName;
  final DetectionConfidence confidence;

  const DetectedMedia({
    required this.kind,
    required this.url,
    this.suggestedFileName,
    this.confidence = DetectionConfidence.high,
  });

  bool get isPathBased => confidence == DetectionConfidence.high;
}

class BrowserDetector {
  static const Map<String, DetectedMediaKind> _extensionMap = {
    '.mp4': DetectedMediaKind.video,
    '.mkv': DetectedMediaKind.video,
    '.avi': DetectedMediaKind.video,
    '.mov': DetectedMediaKind.video,
    '.webm': DetectedMediaKind.video,
    '.flv': DetectedMediaKind.video,
    // Fix #16: HLS and DASH manifests are streaming formats — browsers can
    // play them natively. Classifying them as video caused them to be
    // intercepted as downloads instead of being played in the WebView.
    '.m3u8': DetectedMediaKind.stream,
    '.mpd': DetectedMediaKind.stream,
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
    '.epub': DetectedMediaKind.document,
    '.csv': DetectedMediaKind.document,
    '.zip': DetectedMediaKind.archive,
    '.rar': DetectedMediaKind.archive,
    '.7z': DetectedMediaKind.archive,
    '.tar': DetectedMediaKind.archive,
    '.gz': DetectedMediaKind.archive,
    '.iso': DetectedMediaKind.archive,
    '.xz': DetectedMediaKind.archive,
    '.bz2': DetectedMediaKind.archive,
    '.apk': DetectedMediaKind.executable,
    '.exe': DetectedMediaKind.executable,
    '.dmg': DetectedMediaKind.executable,
    '.pkg': DetectedMediaKind.executable,
    '.deb': DetectedMediaKind.executable,
    '.rpm': DetectedMediaKind.executable,
    '.msi': DetectedMediaKind.executable,
    '.torrent': DetectedMediaKind.torrent,
  };

  /// Content-type patterns that indicate downloadable media
  static const Map<String, DetectedMediaKind> _contentTypeMap = {
    'video/': DetectedMediaKind.video,
    'audio/': DetectedMediaKind.audio,
    'image/': DetectedMediaKind.image,
    'application/pdf': DetectedMediaKind.document,
    'application/zip': DetectedMediaKind.archive,
    'application/x-rar': DetectedMediaKind.archive,
    'application/x-7z': DetectedMediaKind.archive,
    'application/x-bittorrent': DetectedMediaKind.torrent,
    'application/octet-stream': DetectedMediaKind.unknown,
  };

  /// Detect media kind from a Content-Type header value.
  static DetectedMediaKind? detectFromContentType(String contentType) {
    final lower = contentType.toLowerCase().trim();
    for (final entry in _contentTypeMap.entries) {
      if (lower.startsWith(entry.key)) return entry.value;
    }
    return null;
  }

  // CDN URL patterns that often serve media without file extensions
  static const List<String> _cdnMediaPatterns = [
    'googlevideo.com',
    'fbcdn.net',
    'cdninstagram.com',
    'twimg.com',
    'akamaized.net',
  ];

  // Check if URL matches a known CDN media pattern
  static bool isCdnMediaUrl(String url) {
    final lower = url.toLowerCase();
    return _cdnMediaPatterns.any((pattern) => lower.contains(pattern));
  }

  static DetectedMedia? detect(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8') || lower.contains('.mpd')) {
      return DetectedMedia(
        kind: DetectedMediaKind.stream,
        url: url,
        suggestedFileName:
            _suggestName(url, lower.contains('.m3u8') ? '.m3u8' : '.mpd'),
        confidence: DetectionConfidence.high,
      );
    }

    final analysis = SiteIntelligenceService().analyzeUrl(url);

    if (analysis.siteType == SiteType.magnetSource) {
      return DetectedMedia(kind: DetectedMediaKind.magnet, url: url);
    }

    if (analysis.contentHint != ContentHint.unknown) {
      final kind = switch (analysis.contentHint) {
        ContentHint.videoFile => DetectedMediaKind.video,
        // Fix: streaming manifests must be playable in the browser — mapping
        // them to `video` made sites profile a URL as `video`, which triggers
        // isAutoDownloadable() and wrongly intercepts live streams as downloads.
        ContentHint.videoStream => DetectedMediaKind.stream,
        ContentHint.audioFile => DetectedMediaKind.audio,
        ContentHint.audioStream => DetectedMediaKind.stream,
        ContentHint.image => DetectedMediaKind.image,
        ContentHint.document => DetectedMediaKind.document,
        ContentHint.archiveFile => DetectedMediaKind.archive,
        ContentHint.softwarePackage => DetectedMediaKind.executable,
        _ => DetectedMediaKind.unknown,
      };

      if (kind != DetectedMediaKind.unknown) {
        return DetectedMedia(
          kind: kind,
          url: url,
          suggestedFileName: analysis.detectedFileName,
        );
      }
    }

    if (lower.startsWith('magnet:')) {
      return DetectedMedia(kind: DetectedMediaKind.magnet, url: url);
    }

    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final path = uri.path.toLowerCase();
    final cleanPath = path.split('?').first.split('#').first.trim();
    final trimmedPath = cleanPath.endsWith('/')
        ? cleanPath.substring(0, cleanPath.length - 1)
        : cleanPath;

    // Check by file extension (path or query parameters)
    final lowerUrl = url.toLowerCase();
    for (final entry in _extensionMap.entries) {
      final ext = entry.key;
      if (trimmedPath.endsWith(ext)) {
        return DetectedMedia(
          kind: entry.value,
          url: url,
          suggestedFileName: _suggestName(url, ext),
          confidence: DetectionConfidence.high,
        );
      } else if (lowerUrl.contains('$ext?') ||
          lowerUrl.contains('$ext&') ||
          lowerUrl.contains('$ext#') ||
          lowerUrl.contains('file=$ext') ||
          (lowerUrl.contains('filename=') && lowerUrl.contains(ext))) {
        return DetectedMedia(
          kind: entry.value,
          url: url,
          suggestedFileName: _suggestName(url, ext),
          confidence: DetectionConfidence.low,
        );
      }
    }

    final isCleanDownloadRoute = (trimmedPath.endsWith('/download') ||
            trimmedPath.endsWith('/downloads') ||
            trimmedPath == '/download' ||
            trimmedPath == '/downloads') &&
        uri.query.isEmpty;

    if (!isCleanDownloadRoute) {
      final hasDownloadKeyword = lowerUrl.contains('/download') ||
          lowerUrl.contains('download_file') ||
          lowerUrl.contains('attachment') ||
          lowerUrl.contains('?download') ||
          lowerUrl.contains('&download') ||
          lowerUrl.contains('?file=') ||
          lowerUrl.contains('&file=');

      if (hasDownloadKeyword) {
        return DetectedMedia(
          kind: DetectedMediaKind.unknown,
          url: url,
          suggestedFileName: _suggestName(url, ''),
        );
      }
    }

    final webExtensions = [
      '.html',
      '.htm',
      '.php',
      '.jsp',
      '.asp',
      '.aspx',
      '.xhtml',
      '.js',
      '.css'
    ];
    if (webExtensions.any((ext) => trimmedPath.endsWith(ext))) {
      return null;
    }

    return null;
  }

  static bool isAutoDownloadable(String url) {
    if (url.startsWith('magnet:')) return true;
    final detected = detect(url);
    if (detected == null) return false;
    // Fix #16: Excluded DetectedMediaKind.stream — streaming manifests
    // (.m3u8, .mpd) should be passed to the browser for playback, not
    // intercepted as downloads.
    return detected.kind == DetectedMediaKind.archive ||
        detected.kind == DetectedMediaKind.executable ||
        detected.kind == DetectedMediaKind.torrent ||
        detected.kind == DetectedMediaKind.magnet ||
        detected.kind == DetectedMediaKind.video ||
        detected.kind == DetectedMediaKind.audio ||
        detected.kind == DetectedMediaKind.document;
  }

  static String _suggestName(String url, String ext) {
    try {
      final uri = Uri.parse(url);
      final segments =
          uri.pathSegments.where((s) => s.trim().isNotEmpty).toList();
      if (segments.isEmpty) return 'download${ext.isEmpty ? '' : ext}';
      var last = segments.last;
      if (!last.toLowerCase().endsWith(ext) && ext.isNotEmpty) {
        last = '$last$ext';
      }
      return last;
    } catch (e, st) {
      Logger('browser_detector')
          .warning('[browser_detector] operation failed', e, st);
      return 'download${ext.isEmpty ? '' : ext}';
    }
  }
}
