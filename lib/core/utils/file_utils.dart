import 'dart:io';
import 'package:path/path.dart' as p;

const List<String> videoExtensions = [
  'mp4', 'mkv', 'avi', 'mov', 'webm', 'm4v',
];

const List<String> audioExtensions = [
  'mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a',
];

const List<String> documentExtensions = [
  'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'csv',
];

const List<String> archiveExtensions = ['zip', 'rar', '7z', 'tar', 'gz', 'iso'];

String formatBytes(num bytes) {
  if (bytes < 0) bytes = 0;
  const kb = 1024;
  const mb = 1024 * 1024;
  const gb = 1024 * 1024 * 1024;
  if (bytes >= gb) {
    return '${(bytes / gb).toStringAsFixed(1)} GB';
  }
  if (bytes >= mb) {
    return '${(bytes / mb).toStringAsFixed(1)} MB';
  }
  if (bytes >= kb) {
    return '${(bytes / kb).toStringAsFixed(1)} KB';
  }
  return '${bytes.toStringAsFixed(0)} B';
}

String categoryFromFileName(String fileName) {
  final extension = p.extension(fileName).replaceFirst('.', '').toLowerCase();
  if (videoExtensions.contains(extension)) return 'Video';
  if (audioExtensions.contains(extension)) return 'Audio';
  if (documentExtensions.contains(extension)) return 'Document';
  if (archiveExtensions.contains(extension)) return 'Archive';
  if (extension == 'apk') return 'APK';
  return 'Other';
}

const _windowsReserved = {
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};

String safeFileName(String value) {
  var sanitized = value
      .replaceAll(RegExp(r'[<>:"/\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^\.+|\.+$'), '')
      .trim();
  if (sanitized.isEmpty) return 'download.bin';
  if (sanitized.length > 120) {
    final ext = p.extension(sanitized);
    final baseWithoutExt = ext.isNotEmpty && sanitized.endsWith(ext)
        ? sanitized.substring(0, sanitized.length - ext.length)
        : sanitized;
    final maxBaseLength = (120 - ext.length).clamp(0, 120);
    final truncatedBase = baseWithoutExt.substring(
      0,
      baseWithoutExt.length.clamp(0, maxBaseLength),
    );
    sanitized = '$truncatedBase$ext'.trim();
    if (sanitized.isEmpty) return 'download.bin';
  }
  final baseName = sanitized.split('.').first.toUpperCase();
  if (_windowsReserved.contains(baseName)) sanitized = '_$sanitized';
  return sanitized;
}

Future<String> getUniqueFilePath(String directoryPath, String fileName) async {
  final safeName = safeFileName(fileName);
  final ext = p.extension(safeName);
  final nameWithoutExt = ext.isNotEmpty && safeName.endsWith(ext)
      ? safeName.substring(0, safeName.length - ext.length)
      : safeName;
  var candidatePath = p.join(directoryPath, safeName);
  var counter = 1;
  while (await File(candidatePath).exists()) {
    candidatePath = p.join(directoryPath, '$nameWithoutExt ($counter)$ext');
    counter++;
  }
  return candidatePath;
}

String torrentSavePath(String directoryPath, String name) {
  return p.join(directoryPath, safeFileName(name));
}

int scanFolderBytesSync(String path) {
  try {
    final dir = Directory(path);
    if (!dir.existsSync()) return 0;
    var total = 0;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += entity.lengthSync();
        } catch (_) {}
      }
    }
    return total;
  } catch (_) {
    return 0;
  }
}

/// BEST-EFFORT disk scan. The authoritative source for per-file progress
/// is libtorrent's piece-bitfield (getFileProgress), NOT the file size on
/// disk. This function is only used to seed the initial display BEFORE the
/// engine has fetched live progress from libtorrent.
({int total, List<Map<String, dynamic>> files}) scanTorrentFilesOnDisk(
  String saveRoot,
  List<Map<String, dynamic>> fileList,
) {
  var total = 0;
  final files = fileList.map((f) {
    final copy = Map<String, dynamic>.from(f);
    final relPath = copy['name'] as String? ?? '';
    final length = (copy['length'] as num?)?.toInt() ?? 0;
    var downloaded = 0;
    if (relPath.isNotEmpty && length > 0) {
      try {
        final file = File(p.join(saveRoot, relPath));
        if (file.existsSync()) {
          final diskLen = file.lengthSync();
          // FIX(5): libtorrent pre-allocates files to full length, so a full-size file
          // is NOT evidence of completion. Only a short file is a reliable
          // lower bound; a full-size file is ambiguous and must not read 100%.
          if (diskLen > 0 && diskLen < length) {
            downloaded = diskLen;
          }
        }
      } catch (_) {}
    }
    copy['downloadedBytes'] = downloaded;
    copy['progressSource'] = 'disk-scan';
    total += downloaded;
    return copy;
  }).toList();
  return (total: total, files: files);
}

Future<void> deleteDownloadParts(String tempFilePath) async {
  try {
    final dir = File(tempFilePath).parent;
    final name = File(tempFilePath).uri.pathSegments.last;
    await for (final entity in dir.list()) {
      if (entity is File) {
        final fileName = entity.uri.pathSegments.last;
        final isMainTemp = fileName == name;
        final isPart = RegExp(
          '^${RegExp.escape(name)}\\.part\\d+\$',
        ).hasMatch(fileName);
        final isState = fileName == '$name.dmxstate';
        final isJournal = fileName == '$name.journal';
        if (isMainTemp || isPart || isState || isJournal) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }
  } catch (_) {}
}
