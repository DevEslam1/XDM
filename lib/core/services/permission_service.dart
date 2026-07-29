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

      // TODO(scoped-storage): For true public Downloads visibility on Android 11+,
      // implement a platform channel using MediaStore.Downloads API.
      // For now, use app-specific external storage to prevent EACCES crashes.
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

  // TODO(mediastore): On Android 11+ (API 30+) [defaultDownloadDirectory]
  // resolves to app-specific external storage or the app documents directory.
  // Both are INVISIBLE to the system Gallery / Files apps, so downloaded media
  // never shows up for the user. To make media (video/audio/image) publicly
  // visible, add a MethodChannel (e.g. 'dmx/mediastore') whose Android side
  // inserts the file via the MediaStore.Downloads (or MediaStore.Video/Audio/
  // Images) API using ContentResolver.insert(...) and returns the resulting
  // content:// URI (or an openable file descriptor to stream bytes into).
  // Wire that channel into [getMediaStorePath] below and have download save
  // logic prefer it over [defaultDownloadDirectory] for media MIME types.
  //
  /// Returns a MediaStore-backed public path/URI for [fileName] with the given
  /// [mimeType] (e.g. `video/mp4`), making the file visible in the system
  /// Gallery. Returns `null` when unavailable — non-Android, SDK < 29, or the
  /// native platform channel is not yet implemented. Callers MUST fall back to
  /// [defaultDownloadDirectory] when this returns `null`.
  Future<String?> getMediaStorePath(String fileName, String mimeType) async {
    if (kIsWeb || !Platform.isAndroid) return null;
    final sdk = await _androidSdkLevel();
    if (sdk < 29) return null;
    // TODO(mediastore): Invoke the native MediaStore.Downloads platform channel
    // here and return the inserted content:// URI. Returning null for now so
    // callers keep using the app-specific storage fallback.
    return null;
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
      // Fall back to app-private documents directory to guarantee writability.
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
