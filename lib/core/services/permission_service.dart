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
    } catch (e) {
      debugPrint(
        '[PermissionService] Error getting SDK level via DeviceInfo: $e',
      );
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
            if (val >= 21 && val <= 50) return val;
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
      } catch (err) {
        debugPrint('[PermissionService] Fallback SDK level check failed: $err');
      }
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
      } catch (e) {
        debugPrint(
          '[PermissionService] Error getting desktop downloads directory: $e',
        );
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

    if (!kIsWeb && Platform.isAndroid) {
      final sdk = await _androidSdkLevel();

      // Always try the public Downloads folder first
      if (sdk >= 30) {
        try {
          final extDirs = await getExternalStorageDirectories(
            type: StorageDirectory.downloads,
          );
          if (extDirs != null && extDirs.isNotEmpty) {
            final pth = p.join(extDirs.first.path, 'XDM');
            final dir = Directory(pth);
            if (!await dir.exists()) {
              await dir.create(recursive: true);
            }
            return pth;
          }
        } catch (e) {
          debugPrint(
            '[PermissionService] Failed to get external storage directories: $e',
          );
        }
      }

      // Fallback to public Download path — never use Android/data paths
      if (sdk < 30) {
        // On older devices ensure storage permission is granted first
        if (!await _isStorageGranted()) {
          return _fallbackDirectory();
        }
      }

      const publicDownloadPath = '/storage/emulated/0/Download/XDM';
      try {
        final dir = Directory(publicDownloadPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return publicDownloadPath;
      } catch (e) {
        debugPrint(
          '[PermissionService] Failed to create public download path: $e',
        );
      }

      return _fallbackDirectory();
    }

    final docs = await getApplicationDocumentsDirectory();
    final pth = p.join(docs.path, 'XDM');
    final dir = Directory(pth);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return pth;
  }

  Future<String> _fallbackDirectory() async {
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
      // Request opportunistically — helps UX when saving to shared media
      // collections (Gallery, Music). The app's default path
      // (getExternalStorageDirectories → Downloads) is app-specific and
      // requires no media permission on SDK 30+, so we never block here.
      final permissions = <Permission>[
        if (!await Permission.photos.isGranted) Permission.photos,
        if (!await Permission.videos.isGranted) Permission.videos,
        if (!await Permission.audio.isGranted) Permission.audio,
      ];
      if (permissions.isNotEmpty) await permissions.request();
      // Do NOT gate on grant result — fall through to directory creation.
    } else if (sdk >= 29) {
      final status = await Permission.storage.status;
      if (!status.isGranted) {
        if (status.isPermanentlyDenied) {
          return false;
        }
        final requestStatus = await Permission.storage.request();
        if (!requestStatus.isGranted) {
          return false;
        }
      }
    } else {
      final status = await Permission.storage.status;
      if (!status.isGranted) {
        if (status.isPermanentlyDenied) {
          return false;
        }
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
      debugPrint(
        'ensureStorageAccess: failed to create download directory: $e',
      );
      // Avoid Android/data fallbacks — always use public Downloads/XDM
      const fallbackPath = '/storage/emulated/0/Download/XDM';
      try {
        final xdmDir = Directory(fallbackPath);
        if (!await xdmDir.exists()) {
          await xdmDir.create(recursive: true);
        }
        return true;
      } catch (err) {
        debugPrint(
          '[PermissionService] ensureStorageAccess public path fallback failed: $err',
        );
      }
      return false;
    }
  }

  Future<bool> isStoragePermanentlyDenied() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    final sdk = await _androidSdkLevel();
    if (sdk >= 33) {
      return (await Permission.photos.status.isPermanentlyDenied) ||
          (await Permission.videos.status.isPermanentlyDenied) ||
          (await Permission.audio.status.isPermanentlyDenied);
    }
    return (await Permission.storage.status).isPermanentlyDenied;
  }

  Future<bool> isBatteryOptimizationExempt() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      return await Permission.ignoreBatteryOptimizations.status.isGranted;
    } catch (e) {
      return false;
    }
  }

  Future<bool> requestBatteryOptimizationExemption() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      final status = await Permission.ignoreBatteryOptimizations.status;
      if (status.isGranted) return true;

      // On many Android versions Permission.ignoreBatteryOptimizations.request()
      // silently fails without showing a dialog. Instead, open system app
      // settings where the user can manually disable battery optimization.
      await openAppSettings();
      return (await Permission.ignoreBatteryOptimizations.status).isGranted;
    } catch (e) {
      debugPrint(
        '[PermissionService] Battery optimization exemption request failed: $e',
      );
      return false;
    }
  }
}
