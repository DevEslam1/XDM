import 'dart:io';
import 'package:path/path.dart' as p;

const List<String> videoExtensions = [
  'mp4',
  'mkv',
  'avi',
  'mov',
  'webm',
  'm4v',
];
const List<String> audioExtensions = [
  'mp3',
  'wav',
  'flac',
  'aac',
  'ogg',
  'm4a',
];
const List<String> documentExtensions = [
  'pdf',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'txt',
  'csv',
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
  'CON', 'PRN', 'AUX', 'NUL',
  'COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
  'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9',
};

String safeFileName(String value) {
  var sanitized = value
      .replaceAll('+', ' ')
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
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
    final truncatedBase = baseWithoutExt.substring(0, baseWithoutExt.length.clamp(0, maxBaseLength));
    sanitized = '$truncatedBase$ext'.trim();
    if (sanitized.isEmpty) return 'download.bin';
  }
  final baseName = sanitized.split('.').first.toUpperCase();
  if (_windowsReserved.contains(baseName)) sanitized = '_$sanitized';
  return sanitized;
}

/// Generates a unique file path in [directoryPath] for [fileName].
/// If a file with the name already exists, appends `(1)`, `(2)`, etc.
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

