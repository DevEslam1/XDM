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
    } catch (_) {}
    return 0; // Unknown or not Android
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
          final extDirs = await getExternalStorageDirectories(type: StorageDirectory.downloads);
          if (extDirs != null && extDirs.isNotEmpty) {
            final dir = extDirs.first;
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
      } else {
        // API 29 and below: the hardcoded public path is still accessible
        const publicPath = '/storage/emulated/0/Download/XDM';
        try {
          final dir = Directory(publicPath);
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          return publicPath;
        } catch (e) {
          try {
            final extDirs = await getExternalStorageDirectories(type: StorageDirectory.downloads);
            if (extDirs != null && extDirs.isNotEmpty) {
              final dir = extDirs.first;
              if (!await dir.exists()) {
                await dir.create(recursive: true);
              }
              return dir.path;
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
      }
    }

    final docs = await getApplicationDocumentsDirectory();
    final pth = p.join(docs.path, 'XDM');
    final dir = Directory(pth);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return pth;
  }

  /// On modern Android (10+) with scoped storage, explicit storage permission
  /// is not needed when writing to app-specific directories returned by
  /// path_provider. For older Android versions we rely on the manifest
  /// WRITE_EXTERNAL_STORAGE permission which is auto-granted at install time
  /// for targetSdk < 30.
  /// We also check dynamic permissions for older Android SDK versions (API < 33).
  Future<bool> ensureStorageAccess() async {
    if (kIsWeb) return true;
    if (!Platform.isAndroid) return true;

    final sdk = _androidSdkLevel();
    if (sdk > 0 && sdk < 33) {
      // Android 12 or older: request storage permission
      final status = await Permission.storage.status;
      if (!status.isGranted) {
        final requestStatus = await Permission.storage.request();
        if (!requestStatus.isGranted) {
          // If we fail on API 29-32, maybe we can still write to app-specific directories
          // so we don't return false immediately unless it's Android 9 or below.
          if (sdk < 29) {
            return false;
          }
        }
      }
    }

    // Ensure the download directory exists.
    try {
      final path = await defaultDownloadDirectory();
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return true;
    } catch (e) {
      debugPrint('ensureStorageAccess: failed to create download directory: $e');
      // If public Downloads failed, try to fallback to app-specific external files
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
