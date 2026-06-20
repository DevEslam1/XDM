import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  int _androidSdkLevel() {
    try {
      final version = Platform.operatingSystemVersion;
      final apiMatch = RegExp(r'API\s+(\d+)').firstMatch(version);
      if (apiMatch != null) {
        return int.parse(apiMatch.group(1)!);
      }
      final sdkMatch = RegExp(r'SDK\s+(\d+)').firstMatch(version);
      if (sdkMatch != null) {
        return int.parse(sdkMatch.group(1)!);
      }
      // OEM builds may omit "API"/"SDK"; try bare numbers >= 21
      final numMatch = RegExp(r'(\d{2,3})').allMatches(version);
      for (final m in numMatch) {
        final val = int.tryParse(m.group(1)!);
        if (val != null && val >= 21) return val;
      }
    } catch (_) {}
    return 0;
  }

  Future<bool> _isStorageGranted() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    final sdk = _androidSdkLevel();
    if (sdk >= 30) return true;
    return await Permission.storage.isGranted;
  }

  Future<String> defaultDownloadDirectory() async {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        final pth = p.join(downloads.path, 'XDM');
        final dir = Directory(pth);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return pth;
      }
    }

    // On Android:
    // - API 30+ (Android 11+): use scoped storage APIs only (hardcoded paths don't work)
    // - API 29 and below: try shared Downloads folder first, fall back to scoped storage
    if (!kIsWeb && Platform.isAndroid) {
      final sdk = _androidSdkLevel();

      // On API 30+, skip hardcoded path — it requires MANAGE_EXTERNAL_STORAGE which
      // most users won't grant. Use path_provider scoped storage APIs directly.
      if (sdk >= 30) {
        try {
          final dir = await getDownloadsDirectory();
          if (dir != null) {
            final pth = p.join(dir.path, 'XDM');
            final xdmDir = Directory(pth);
            if (!await xdmDir.exists()) {
              await xdmDir.create(recursive: true);
            }
            return pth;
          }
        } catch (_) {}
        try {
          final extDir = await getExternalStorageDirectory();
          if (extDir != null) {
            final pth = p.join(extDir.path, 'Download');
            final dir = Directory(pth);
            if (!await dir.exists()) {
              await dir.create(recursive: true);
            }
            return pth;
          }
        } catch (_) {}
      } else if (await _isStorageGranted()) {
        // API 29 and below with storage granted: the hardcoded public path is accessible
        const publicPath = '/storage/emulated/0/Download/XDM';
        try {
          final dir = Directory(publicPath);
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          return publicPath;
        } catch (e) {
          debugPrint('Failed to create public download path: $e');
        }
      }

      // Fallback for API 29- or when above paths fail: try app-specific directories
      try {
        final dir = await getDownloadsDirectory();
        if (dir != null) {
          final pth = p.join(dir.path, 'XDM');
          final xdmDir = Directory(pth);
          if (!await xdmDir.exists()) {
            await xdmDir.create(recursive: true);
          }
          return pth;
        }
      } catch (_) {}
      try {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          final pth = p.join(extDir.path, 'Download');
          final dir = Directory(pth);
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          return pth;
        }
      } catch (_) {}
    }

    final docs = await getApplicationDocumentsDirectory();
    final pth = p.join(docs.path, 'XDM');
    final dir = Directory(pth);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return pth;
  }

  Future<bool> ensureStorageAccess() async {
    if (kIsWeb) return true;
    if (!Platform.isAndroid) return true;

    final sdk = _androidSdkLevel();
    if (sdk > 0 && sdk < 33) {
      final status = await Permission.storage.status;
      if (!status.isGranted) {
        final requestStatus = await Permission.storage.request();
        if (!requestStatus.isGranted) {
          if (sdk < 29) return false;
        }
      }
    }

    try {
      final path = await defaultDownloadDirectory();
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return true;
    } catch (e) {
      debugPrint('ensureStorageAccess: failed to create download directory: $e');
      try {
        final dir = await getDownloadsDirectory();
        if (dir != null) {
          final xdmDir = Directory(p.join(dir.path, 'XDM'));
          if (!await xdmDir.exists()) {
            await xdmDir.create(recursive: true);
          }
          return true;
        }
      } catch (_) {}
      try {
        final extDirs = await getExternalStorageDirectories(type: StorageDirectory.downloads);
        if (extDirs != null && extDirs.isNotEmpty) {
          final dir = extDirs.first;
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          return true;
        }
      } catch (_) {}
      return false;
    }
  }
}
