import 'dart:io';

import 'package:dmx/core/services/logging_service.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

import '../services/site_intelligence/site_intelligence_service.dart';

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

String categoryFromFileName(String fileName,
    {SiteType? siteType, ContentHint? contentHint}) {
  if (contentHint != null) {
    switch (contentHint) {
      case ContentHint.videoFile:
      case ContentHint.videoStream:
        return 'Video';
      case ContentHint.audioFile:
      case ContentHint.audioStream:
        return 'Audio';
      case ContentHint.archiveFile:
        return 'Archive';
      case ContentHint.softwarePackage:
        return 'APK';
      case ContentHint.document:
        return 'Document';
      case ContentHint.image:
        return 'Image';
      default:
        break;
    }
  }

  if (siteType != null) {
    if (siteType == SiteType.videoStreaming) return 'Video';
    if (siteType == SiteType.audioStreaming) return 'Audio';
  }

  final extension = p.extension(fileName).replaceFirst('.', '').toLowerCase();
  if (videoExtensions.contains(extension)) return 'Video';
  if (audioExtensions.contains(extension)) return 'Audio';
  if (documentExtensions.contains(extension)) return 'Document';
  if (archiveExtensions.contains(extension)) return 'Archive';
  if (extension == 'apk') return 'APK';
  return 'Other';
}

String resolveCategorySmart({
  required String url,
  String? fileName,
  SiteType? siteType,
  ContentHint? contentHint,
  String? magnetName,
}) {
  return SiteIntelligenceService().resolveCategory(
    url: url,
    fileName: fileName,
    siteType: siteType,
    contentHint: contentHint,
    magnetName: magnetName,
  );
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
      // Step 1: strip null bytes and ASCII/Unicode control characters
      .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '')
      // Step 2: strip leading/repeated path traversal sequences
      .replaceAll(RegExp(r'\.\.[/\\]+'), '_')
      // Step 3: replace path separators and invalid chars with an underscore
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      // Step 4: collapse runs of dots or underscores
      .replaceAll(RegExp(r'\.{2,}'), '.')
      .replaceAll(RegExp(r'_{2,}'), '_')
      // Step 5: normalise whitespace
      .replaceAll(RegExp(r'\s+'), ' ')
      // Step 6: strip leading/trailing dots and underscores
      .replaceAll(RegExp(r'^[\._]+|[\._]+$'), '')
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

final _filePathLock = Lock();

Future<String> getUniqueFilePath(String directoryPath, String fileName) {
  return _filePathLock.synchronized(() async {
    final safeName = safeFileName(fileName);
    final ext = p.extension(safeName);
    final nameWithoutExt = ext.isNotEmpty && safeName.endsWith(ext)
        ? safeName.substring(0, safeName.length - ext.length)
        : safeName;
    var candidatePath = p.join(directoryPath, safeName);
    var counter = 1;
    while (await FileSystemEntity.type(candidatePath) !=
        FileSystemEntityType.notFound) {
      candidatePath = p.join(directoryPath, '$nameWithoutExt ($counter)$ext');
      counter++;
    }
    return candidatePath;
  });
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
        } catch (e) {
          LoggingService.logger('FileUtils').info(
            '[FileUtils] per-file length read skipped (best-effort scan): $e',
          );
        }
      }
    }
    return total;
  } catch (e) {
    LoggingService.logger('FileUtils').info(
      '[FileUtils] folder scan skipped (best-effort, returning 0): $e',
    );
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
        // SECURITY: Guard against path traversal in stored file entries.
        final canonicalRoot = p.canonicalize(saveRoot);
        final candidatePath = p.canonicalize(p.join(saveRoot, relPath));
        if (!p.isWithin(canonicalRoot, candidatePath)) {
          LoggingService.logger('FileUtils').warning(
            '[FileUtils] scanTorrentFilesOnDisk: blocked traversal for '
            'relPath="$relPath"',
          );
        } else {
          final file = File(candidatePath);
          if (file.existsSync()) {
            final diskLen = file.lengthSync();
            final storedDownloaded =
                (copy['downloadedBytes'] as num?)?.toInt() ?? 0;
            if (storedDownloaded > 0) {
              downloaded = storedDownloaded;
            } else if (diskLen > 0 && diskLen < length) {
              // Probe head to confirm real data
              try {
                final raf = file.openSync();
                final probeSize = diskLen < 4096 ? diskLen : 4096;
                final probe = raf.readSync(probeSize);
                raf.closeSync();
                final hasContent = probe.any((b) => b != 0);
                downloaded = hasContent ? diskLen : 0;
              } catch (_) {
                downloaded = diskLen; // fallback
              }
            } else if (diskLen >= length) {
              try {
                final raf = file.openSync();
                final probeSize = diskLen < 4096 ? diskLen : 4096;
                final headProbe = raf.readSync(probeSize);
                final headHasContent = headProbe.any((b) => b != 0);

                bool tailHasContent = headHasContent;
                if (diskLen > 8192) {
                  raf.setPositionSync(diskLen - 4096);
                  final tailProbe = raf.readSync(4096);
                  tailHasContent = tailProbe.any((b) => b != 0);
                }
                raf.closeSync();

                final isPartial = headHasContent && !tailHasContent;
                if (isPartial) {
                  downloaded = (diskLen * 0.5).round();
                  LoggingService.logger('FileUtils').info(
                    '[FileUtils] File "$relPath" appears partially downloaded '
                    '(head has data, tail is zeros). Estimated 50%.',
                  );
                } else if (headHasContent && tailHasContent) {
                  downloaded = length;
                } else {
                  downloaded = 0;
                  LoggingService.logger('FileUtils').info(
                    '[FileUtils] File "$relPath" appears pre-allocated '
                    '(full size but empty content). Setting downloaded=0.',
                  );
                }
              } catch (probeErr) {
                downloaded = 0;
              }
            }
          }
        }
      } catch (e) {
        LoggingService.logger('FileUtils').info(
          '[FileUtils] per-file disk size read skipped (best-effort scan): $e',
        );
      }
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
          } catch (e) {
            LoggingService.logger('FileUtils').info(
              '[FileUtils] deleting download part failed (may already be gone): $e',
            );
          }
        }
      }
    }
  } catch (e) {
    LoggingService.logger('FileUtils').info(
      '[FileUtils] download parts cleanup skipped: $e',
    );
  }
}

bool isTorrentFileSelected(Map f) {
  final sel = f['selected'];
  if (sel is bool) return sel;
  return sel != false;
}

/// Sanitizes a file name, stripping path traversal sequences and illegal OS characters.
String sanitizeFileName(String fileName) {
  var name = fileName.trim();
  name = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
  name = name.replaceAll(RegExp(r'[\\\/]'), '_');
  name = name.replaceAll('..', '_');
  name = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.replaceAll('_', '').trim().isEmpty) {
    return 'download_${DateTime.now().millisecondsSinceEpoch}';
  }
  final base = p.basenameWithoutExtension(name);
  const windowsReserved = {
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
  if (windowsReserved.contains(base.toUpperCase())) {
    name = '_$name';
  }
  if (name.length > 255) {
    final finalExt = p.extension(name);
    final finalBase = p.basenameWithoutExtension(name);
    name =
        '${finalBase.substring(0, (255 - finalExt.length).clamp(1, 255))}$finalExt';
  }
  return name;
}

/// Validates that [targetPath] resolves safely within [rootDirectory] to prevent directory traversal.
bool isSafeSubpath(String rootDirectory, String targetPath) {
  try {
    final rootDir = Directory(rootDirectory);
    final targetDir = Directory(targetPath);
    final targetFile = File(targetPath);
    final canonicalRoot = rootDir.existsSync()
        ? rootDir.resolveSymbolicLinksSync()
        : p.canonicalize(rootDirectory);
    final canonicalTarget = targetFile.existsSync()
        ? targetFile.resolveSymbolicLinksSync()
        : (targetDir.existsSync()
            ? targetDir.resolveSymbolicLinksSync()
            : p.canonicalize(targetPath));
    return p.isWithin(canonicalRoot, canonicalTarget) ||
        canonicalRoot == canonicalTarget;
  } catch (_) {
    final canonicalRoot = p.canonicalize(rootDirectory);
    final canonicalTarget = p.canonicalize(targetPath);
    return p.isWithin(canonicalRoot, canonicalTarget) ||
        canonicalRoot == canonicalTarget;
  }
}
