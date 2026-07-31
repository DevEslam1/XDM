import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static int? _cachedSdkLevel;

  Future<int> _androidSdkLevel() async {
    if (_cachedSdkLevel != null && _cachedSdkLevel! > 0) return _cachedSdkLevel!;
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
      // FIX(19): only trust an explicit API/SDK number from the OS version
      // string. The old heuristic (grabbing any bare number and mapping
      // Android version names like "13" to API levels) was unreliable.
      try {
        final version = Platform.operatingSystemVersion;
        final match = RegExp(
          r'(?:API|SDK)\s+(\d+)',
          caseSensitive: false,
        ).firstMatch(version);
        if (match != null) {
          final sdk = int.tryParse(match.group(1)!);
          if (sdk != null && sdk > 0) {
            _cachedSdkLevel = sdk;
            return sdk;
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
        // App-specific external storage unavailable — fall through to the
        // always-writable app documents directory to prevent EACCES crashes.
        return _fallbackDirectory();
      }

      // SDK < 30: the public Download path is writable with storage permission.
      if (!await _isStorageGranted()) {
        return _fallbackDirectory();
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

  /// Inserts a completed download into the system MediaStore.Downloads
  /// collection so it becomes visible in the system Files / Downloads apps.
  ///
  /// Returns the content:// URI (SDK 30+) or file path (SDK 29) on success,
  /// or `null` on failure / unsupported platform.
  /// Silently returns null on non-Android, web, or SDK < 29.
  Future<String?> insertIntoMediaStore(
    String fileName,
    String mimeType,
    String sourcePath,
  ) async {
    if (kIsWeb || !Platform.isAndroid) return null;
    final sdk = await _androidSdkLevel();
    if (sdk < 29) return null;
    try {
      const channel = MethodChannel('com.dmx.app/media');
      final result = await channel.invokeMethod<String>('insertDownload', {
        'fileName': fileName,
        'mimeType': mimeType,
        'sourcePath': sourcePath,
      });
      return result;
    } catch (e) {
      debugPrint('[PermissionService] MediaStore insertion failed: $e');
      return null;
    }
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
      // FIX(19): roll back to the app-private documents directory (always
      // writable) instead of reporting failure outright — this keeps the
      // app functional even when shared/external storage is unavailable.
      try {
        final fallback = await _fallbackDirectory();
        final dir = Directory(fallback);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return true;
      } catch (fallbackError) {
        debugPrint(
          'ensureStorageAccess: fallback directory also failed: $fallbackError',
        );
        return false;
      }
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

      final result = await Permission.ignoreBatteryOptimizations.request();
      if (result.isGranted) return true;

      // Fallback if not granted directly
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
