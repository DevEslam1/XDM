import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PermissionService {
  Future<String> defaultDownloadDirectory() async {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return p.join(downloads.path, 'XDM');
    }

    // On Android, try the shared Downloads folder. If creation fails (e.g. Android 10+ scoped storage restrictions),
    // fallback to app-specific external downloads directory which is always writable.
    if (!kIsWeb && Platform.isAndroid) {
      const publicPath = '/storage/emulated/0/Download/XDM';
      try {
        final dir = Directory(publicPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return publicPath;
      } catch (e) {
        final extDirs = await getExternalStorageDirectories(type: StorageDirectory.downloads);
        if (extDirs != null && extDirs.isNotEmpty) {
          return extDirs.first.path;
        }
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          return p.join(extDir.path, 'Download');
        }
      }
    }

    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'XDM');
  }

  /// On modern Android (10+) with scoped storage, explicit storage permission
  /// is not needed when writing to app-specific directories returned by
  /// path_provider. For older Android versions we rely on the manifest
  /// WRITE_EXTERNAL_STORAGE permission which is auto-granted at install time
  /// for targetSdk < 30.
  Future<bool> ensureStorageAccess() async {
    if (kIsWeb) return true;
    if (!Platform.isAndroid) return true;

    // With scoped storage (Android 10+) and path_provider directories,
    // no runtime permission request is needed.
    // Ensure the download directory exists.
    final dir = Directory(await defaultDownloadDirectory());
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return true;
  }
}
