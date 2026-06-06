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

String safeFileName(String value) {
  final sanitized = value
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return sanitized.isEmpty ? 'download.bin' : sanitized;
}
