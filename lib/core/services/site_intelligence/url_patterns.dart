/// Regular expression patterns for site detection and metadata extraction.
class UrlPatterns {
  // Quality markers: 1080p, 720p, 4k, 2160p, 480p, 360p, 240p
  static final qualityRegex =
      RegExp(r'(240|360|480|720|1080|2160|1440|4[kK])p?', caseSensitive: false);

  // Common video extensions
  static const videoExtensions = {
    '.mp4',
    '.mkv',
    '.avi',
    '.mov',
    '.wmv',
    '.flv',
    '.webm',
    '.m4v',
    '.ts',
    '.m3u8'
  };

  // Common audio extensions
  static const audioExtensions = {
    '.mp3',
    '.m4a',
    '.flac',
    '.wav',
    '.ogg',
    '.opus',
    '.wma',
    '.aac'
  };

  // Common archive extensions
  static const archiveExtensions = {
    '.zip',
    '.rar',
    '.7z',
    '.tar',
    '.gz',
    '.bz2',
    '.xz',
    '.iso'
  };

  // Common software extensions
  static const softwareExtensions = {
    '.exe',
    '.msi',
    '.apk',
    '.dmg',
    '.deb',
    '.rpm',
    '.appimage',
    '.pkg',
    '.jar'
  };

  // Common document extensions
  static const documentExtensions = {
    '.pdf',
    '.doc',
    '.docx',
    '.xls',
    '.xlsx',
    '.ppt',
    '.pptx',
    '.txt',
    '.epub',
    '.mobi'
  };

  // Common image extensions
  static const imageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
    '.svg',
    '.tiff'
  };

  // Magnet link patterns
  static final magnetHashRegex =
      RegExp(r'xt=urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})');
  static final magnetNameRegex = RegExp(r'dn=([^&]+)');
  static final magnetTrackerRegex = RegExp(r'tr=([^&]+)');

  // Known download token/expiry parameter names
  static final expiryParams = {
    'token',
    'expires',
    'expire',
    'signature',
    'sig',
    'auth',
    'auth_token',
    'access_token',
    'exp_time',
    'st_token',
    'download_key',
  };

  /// Checks if a query parameter key/value pair indicates URL expiration or signing.
  static bool isExpiryOrSignatureParam(String key, String value) {
    final lowerKey = key.toLowerCase();
    if (expiryParams.contains(lowerKey)) return true;
    if (lowerKey == 'st' || lowerKey == 'exp') {
      final numVal = int.tryParse(value);
      if (numVal != null && numVal > 1000000000) return true;
    } else if (lowerKey == 'h' || lowerKey == 'key') {
      if (value.length >= 16 && RegExp(r'^[a-fA-F0-9_-]+$').hasMatch(value)) {
        return true;
      }
    }
    return false;
  }

  // Torrent group/quality patterns for magnet name parsing
  static final releaseGroupRegex = RegExp(r'^\[([^\]]+)\]');
  static final yearRegex = RegExp(r'\.(19|20)\d{2}\.');
  static final videoCodecRegex =
      RegExp(r'(x264|x265|hevc|h264|h265|av1)', caseSensitive: false);
  static final audioCodecRegex =
      RegExp(r'(aac|ac3|dts|flac|mp3|opus)', caseSensitive: false);
  static final sourceRegex =
      RegExp(r'(bluray|web-dl|webrip|brrip|dvdrip|hdtv)', caseSensitive: false);
}
