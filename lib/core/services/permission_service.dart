import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static int? _cachedSdkLevel;

  Future<int> _androidSdkLevel() async {
    if (_cachedSdkLevel != null) return _cachedSdkLevel!;
    if (kIsWeb) return 0;
    if (!Platform.isAndroid) return 0;
    try {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      _cachedSdkLevel = androidInfo.version.sdkInt;
      return _cachedSdkLevel!;
    } catch (_) {
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
        final match = RegExp(r'\b(\d+)\b').firstMatch(version);
        if (match != null) {
          final val = int.tryParse(match.group(1)!);
          if (val != null) {
            if (val >= 21 && val <= 35) return val;
            return switch (val) {
              14 => 34,
              13 => 33,
              12 => 31,
              11 => 30,
              10 => 29,
              9 => 28,
              8 => 26,
              7 => 24,
              6 => 23,
              5 => 21,
              _ => 0,
            };
          }
        }
      } catch (_) {}
    }
    return 0;
  }

  Future<bool> _isStorageGranted() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    final sdk = await _androidSdkLevel();
    if (sdk >= 30) return true;
    return await Permission.storage.isGranted;
  }

  Future<String> defaultDownloadDirectory() async {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      try {
        final downloads = await getDownloadsDirectory();
        if (downloads != null) {
          final pth = p.join(downloads.path, 'XDM');
          final dir = Directory(pth);
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          return pth;
        }
      } catch (_) {
        String? home;
        if (Platform.isWindows) {
          home = Platform.environment['USERPROFILE'];
        } else if (Platform.isLinux) {
          home = Platform.environment['HOME'];
        }
        if (home != null) {
          final pth = p.join(home, 'Downloads', 'XDM');
          final dir = Directory(pth);
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          return pth;
        }
      }
    }

    // On Android:
    // - API 30+ (Android 11+): use scoped storage APIs only (hardcoded paths don't work)
    // - API 29 and below: try shared Downloads folder first, fall back to scoped storage
    if (!kIsWeb && Platform.isAndroid) {
      final sdk = await _androidSdkLevel();

      // On API 30+, try SAF-style public path via getExternalStorageDirectory,
      // then fall back to app-specific directory. The getDownloadsDirectory()
      // returns an app-private dir on API 30+ which users cannot browse.
      if (sdk >= 30) {
        // Try public Downloads via external storage directory
        try {
          final extDir = await getExternalStorageDirectory();
          if (extDir != null) {
            // Navigate up to the actual external storage root, then to Download/XDM
            final root = extDir.path;
            final parts = root.split('/');
            final androidIndex = parts.indexOf('Android');
            if (androidIndex > 0) {
              final publicPath = p.join(
                p.joinAll(parts.sublist(0, androidIndex)), 'Download', 'XDM',
              );
              final dir = Directory(publicPath);
              if (!await dir.exists()) {
                await dir.create(recursive: true);
              }
              return publicPath;
            }
          }
        } catch (_) {}
        // Fallback to app-specific directory
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

    final sdk = await _androidSdkLevel();
    if (sdk >= 33) {
      // Only request permissions that are not already granted
      final permissions = [
        if (!await Permission.photos.isGranted) Permission.photos,
        if (!await Permission.videos.isGranted) Permission.videos,
        if (!await Permission.audio.isGranted) Permission.audio,
      ];
      if (permissions.isNotEmpty) {
        await permissions.request();
      }
    } else if (sdk >= 29) {
      final status = await Permission.storage.status;
      if (!status.isGranted) {
        final requestStatus = await Permission.storage.request();
        if (!requestStatus.isGranted) {
          return false;
        }
      }
    } else {
      final status = await Permission.storage.status;
      if (!status.isGranted) {
        final requestStatus = await Permission.storage.request();
        if (!requestStatus.isGranted) {
          return false;
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
