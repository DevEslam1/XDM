import 'dart:core';

/// Pure domain value object representing download metadata.
class UrlResourceMetadata {
  final String url;
  final String fileName;
  final String? extension;
  final int fileSize;
  final String category;
  final bool isTorrent;
  final String? torrentInfoHash;
  final String? audioUrl;
  final int? audioSize;
  final String? thumbnailUrl;
  final List<TorrentFileSelection> torrentFiles;

  const UrlResourceMetadata({
    required this.url,
    required this.fileName,
    this.extension,
    this.fileSize = 0,
    this.category = 'Auto',
    this.isTorrent = false,
    this.torrentInfoHash,
    this.audioUrl,
    this.audioSize,
    this.thumbnailUrl,
    this.torrentFiles = const [],
  });

  UrlResourceMetadata copyWith({
    String? url,
    String? fileName,
    String? extension,
    int? fileSize,
    String? category,
    bool? isTorrent,
    String? torrentInfoHash,
    String? audioUrl,
    int? audioSize,
    String? thumbnailUrl,
    List<TorrentFileSelection>? torrentFiles,
  }) {
    return UrlResourceMetadata(
      url: url ?? this.url,
      fileName: fileName ?? this.fileName,
      extension: extension ?? this.extension,
      fileSize: fileSize ?? this.fileSize,
      category: category ?? this.category,
      isTorrent: isTorrent ?? this.isTorrent,
      torrentInfoHash: torrentInfoHash ?? this.torrentInfoHash,
      audioUrl: audioUrl ?? this.audioUrl,
      audioSize: audioSize ?? this.audioSize,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      torrentFiles: torrentFiles ?? this.torrentFiles,
    );
  }
}

/// Pure domain value object representing a file within a torrent archive.
class TorrentFileSelection {
  final int index;
  final String path;
  final int size;
  final bool selected;

  const TorrentFileSelection({
    required this.index,
    required this.path,
    required this.size,
    this.selected = true,
  });

  TorrentFileSelection copyWith({
    int? index,
    String? path,
    int? size,
    bool? selected,
  }) {
    return TorrentFileSelection(
      index: index ?? this.index,
      path: path ?? this.path,
      size: size ?? this.size,
      selected: selected ?? this.selected,
    );
  }

  Map<String, dynamic> toMap() => {
        'index': index,
        'path': path,
        'size': size,
        'selected': selected,
      };

  factory TorrentFileSelection.fromMap(Map<String, dynamic> map) {
    return TorrentFileSelection(
      index: (map['index'] as num?)?.toInt() ?? 0,
      path: map['path'] as String? ?? '',
      size: (map['size'] as num?)?.toInt() ?? 0,
      selected: map['selected'] as bool? ?? true,
    );
  }
}

enum TorrentUriKind {
  torrentFile,
  magnet,
  notTorrent,
}

/// Domain URL specifications & validation utilities.
class UrlSpecifications {
  const UrlSpecifications._();

  static bool isHttpUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  static bool isMagnetUrl(String value, {bool strict = true}) {
    final clean = value.trim();
    if (!clean.toLowerCase().startsWith('magnet:')) return false;
    
    // In lenient/non-strict mode, accept tracker-only magnets
    if (!strict && clean.contains('tr=') && !clean.contains('xt=')) return true;

    final parsed = parseMagnetUrl(clean);
    final infoHash = parsed['infoHash'] as String?;
    if (infoHash == null || infoHash.isEmpty) return false;

    final isHex40 = RegExp(r'^[A-Fa-f0-9]{40}$').hasMatch(infoHash);
    final isBase32 = RegExp(r'^[A-Z2-7]{32}$').hasMatch(infoHash);
    final isHex64 = RegExp(r'^[A-Fa-f0-9]{64}$').hasMatch(infoHash);
    // Multihash prefix format (e.g. 1220 followed by 64 hex chars for sha256)
    final isBtmh = RegExp(r'^(1220)?[A-Fa-f0-9]{64}$').hasMatch(infoHash);
    return isHex40 || isBase32 || isHex64 || isBtmh;
  }

  static bool isTorrentFileUrl(String value, {String? mimeType}) {
    if (mimeType != null && mimeType.trim().toLowerCase() == 'application/x-bittorrent') {
      return true;
    }
    final clean = value.trim().toLowerCase();
    final uri = Uri.tryParse(clean);
    final path = uri?.path.toLowerCase() ?? clean;

    if (clean.startsWith('content://')) {
      return path.endsWith('.torrent') ||
          clean.contains('.torrent?') ||
          clean.contains('.torrent#') ||
          clean.endsWith('.torrent');
    }

    if (clean.startsWith('file://')) {
      return path.endsWith('.torrent') ||
          clean.contains('.torrent?') ||
          clean.contains('.torrent#');
    }

    return path.endsWith('.torrent') ||
        clean.endsWith('.torrent') ||
        clean.contains('.torrent?') ||
        clean.contains('.torrent#');
  }

  static TorrentUriKind resolveTorrentUriKind(Uri uri, {String? mimeType}) {
    final uriStr = uri.toString();
    if (uri.scheme.toLowerCase() == 'magnet') {
      return isMagnetUrl(uriStr) ? TorrentUriKind.magnet : TorrentUriKind.notTorrent;
    }
    if (isTorrentFileUrl(uriStr, mimeType: mimeType)) {
      return TorrentUriKind.torrentFile;
    }
    return TorrentUriKind.notTorrent;
  }

  static bool isValidTransmissionUrl(String value) {
    return isHttpUrl(value) || isMagnetUrl(value) || isTorrentFileUrl(value);
  }

  static Map<String, dynamic> parseMagnetUrl(String magnet) {
    final result = <String, dynamic>{
      'name': null,
      'infoHash': null,
      'trackers': <String>[],
    };

    final uri = Uri.tryParse(magnet);
    if (uri == null) return result;

    final queryParams = uri.queryParametersAll;

    if (queryParams.containsKey('dn')) {
      result['name'] = queryParams['dn']?.first;
    }

    if (queryParams.containsKey('xt')) {
      for (final String xt in queryParams['xt'] ?? const <String>[]) {
        if (xt.startsWith('urn:btih:')) {
          result['infoHash'] = xt.substring(9).toUpperCase();
          break;
        } else if (xt.startsWith('urn:btmh:')) {
          result['infoHash'] = xt.substring(9).toUpperCase();
          break;
        }
      }
    }

    if (queryParams.containsKey('tr')) {
      result['trackers'] =
          List<String>.from(queryParams['tr'] ?? const <String>[]);
    }

    return result;
  }
}
