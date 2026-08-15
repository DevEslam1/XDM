import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class DesktopUpdateInfo {
  final String version;
  final int build;
  final String downloadUrl;
  final String sha256;
  final String releaseNotes;
  final bool mandatory;

  const DesktopUpdateInfo({
    required this.version,
    required this.build,
    required this.downloadUrl,
    required this.sha256,
    required this.releaseNotes,
    required this.mandatory,
  });

  factory DesktopUpdateInfo.fromJson(Map<String, dynamic> json) {
    return DesktopUpdateInfo(
      version: json['version'] as String? ?? '1.0.0',
      build: json['build'] as int? ?? 1,
      downloadUrl: json['url'] as String? ?? '',
      sha256: json['sha256'] as String? ?? '',
      releaseNotes: json['notes'] as String? ?? '',
      mandatory: json['mandatory'] as bool? ?? false,
    );
  }
}

class DesktopUpdateService {
  static final _log = Logger('DesktopUpdateService');
  static const _manifestUrl =
      'https://raw.githubusercontent.com/DevEslam1/XDM/main/updates/desktop_manifest.json';
  static const _mirrorUrl =
      'https://cdn.jsdelivr.net/gh/DevEslam1/XDM@main/updates/desktop_manifest.json';

  Future<DesktopUpdateInfo?> checkForUpdate({int? currentBuild}) async {
    try {
      final manifest = await _fetchManifest();
      if (manifest == null) return null;

      final platformKey = _currentPlatform();
      final platformData = manifest[platformKey] as Map<String, dynamic>?;
      if (platformData == null) return null;

      final info = DesktopUpdateInfo.fromJson(platformData);
      final current = currentBuild ?? 1;

      if (info.build > current) {
        return info;
      }
      return null;
    } catch (e) {
      _log.warning('Desktop update check failed', e);
      return null;
    }
  }

  Future<Map<String, dynamic>?> _fetchManifest() async {
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 5)));
    try {
      final response = await dio.get(_manifestUrl);
      if (response.data is Map<String, dynamic>) {
        return response.data as Map<String, dynamic>;
      } else if (response.data is String) {
        return jsonDecode(response.data as String) as Map<String, dynamic>;
      }
    } catch (e) {
      _log.info(
        '[DesktopUpdateService] primary manifest fetch failed, falling back to mirror: $e',
      );
      try {
        final response = await dio.get(_mirrorUrl);
        if (response.data is Map<String, dynamic>) {
          return response.data as Map<String, dynamic>;
        } else if (response.data is String) {
          return jsonDecode(response.data as String) as Map<String, dynamic>;
        }
      } catch (e) {
        _log.severe(
            'Failed to fetch update manifest from both primary and mirror URLs',
            e);
      }
    }
    return null;
  }

  Future<bool> downloadAndApply(
    DesktopUpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final fileName = p.basename(Uri.parse(info.downloadUrl).path);
      final downloadPath = p.join(tempDir.path, fileName);

      await Dio().download(
        info.downloadUrl,
        downloadPath,
        onReceiveProgress: (received, total) {
          if (total > 0 && onProgress != null) {
            onProgress(received / total);
          }
        },
      );

      if (info.sha256.isNotEmpty) {
        final valid = await _verifySha256(downloadPath, info.sha256);
        if (!valid) {
          _log.severe('SHA-256 mismatch for desktop update file');
          try {
            await File(downloadPath).delete();
          } catch (e, st) {
      LoggingService.logger('DesktopUpdateService').warning('Operation failed', e, st);
    }
          return false;
        }
      }

      final sigValid = await _verifyCodeSignature(downloadPath);
      if (!sigValid) {
        _log.severe(
          'Code signature verification failed for desktop update file',
        );
        try {
          await File(downloadPath).delete();
        } catch (e, st) {
      LoggingService.logger('DesktopUpdateService').warning('Operation failed', e, st);
    }
        return false;
      }

      if (Platform.isWindows) {
        final result = await Process.run(downloadPath, ['/S']);
        return result.exitCode == 0;
      } else if (Platform.isMacOS) {
        return await _installMacosUpdate(downloadPath);
      } else if (Platform.isLinux) {
        await Process.run('chmod', ['+x', downloadPath]);
        final targetDir = '${Platform.environment['HOME']}/.local/bin';
        await Process.run('mkdir', ['-p', targetDir]);
        final result =
            await Process.run('mv', [downloadPath, '$targetDir/dmx']);
        return result.exitCode == 0;
      }
      return false;
    } catch (e) {
      _log.severe('Desktop update download or install failed', e);
      return false;
    }
  }

  /// Mounts the DMG, copies the .app bundle to /Applications using ditto
  /// (preserves macOS metadata/resource forks), then detaches the volume.
  Future<bool> _installMacosUpdate(String dmgPath) async {
    String? mountPoint;
    try {
      final mountResult = await Process.run(
        'hdiutil',
        ['attach', '-nobrowse', '-plist', dmgPath],
      );
      if (mountResult.exitCode != 0) {
        _log.severe('Failed to mount DMG: ${mountResult.stderr}');
        return false;
      }

      // Parse mount point from plist XML output.
      // The output contains <string>/Volumes/SomeName</string> entries;
      // the mount point is the last /Volumes/ path in the plist.
      final stdout = mountResult.stdout as String;
      final volumeMatches =
          RegExp(r'<string>(/Volumes/[^<]+)</string>').allMatches(stdout);
      if (volumeMatches.isEmpty) {
        _log.severe('Could not parse mount point from hdiutil output');
        return false;
      }
      // ignore: unnecessary_null_checks
      mountPoint = volumeMatches.last.group(1)!;

      // Find .app bundle inside the mounted volume.
      final entities = Directory(mountPoint).listSync();
      Directory? appBundle;
      for (final entity in entities) {
        if (entity is Directory && entity.path.endsWith('.app')) {
          appBundle = entity;
          break;
        }
      }
      if (appBundle == null) {
        _log.severe('No .app bundle found inside mounted DMG');
        return false;
      }

      final appName = p.basename(appBundle.path);
      final targetPath = '/Applications/$appName';
      final stagingPath = '/Applications/$appName.new';

      // Remove leftover staging dir if any
      final stagingDir = Directory(stagingPath);
      if (await stagingDir.exists()) {
        await stagingDir.delete(recursive: true);
      }

      // Use ditto to copy to staging path first — preserves resource forks,
      // extended attributes, and HFS metadata without touching active app.
      final copyResult =
          await Process.run('ditto', [appBundle.path, stagingPath]);
      if (copyResult.exitCode != 0) {
        _log.severe('Failed to copy app bundle: ${copyResult.stderr}');
        if (await stagingDir.exists()) {
          await stagingDir.delete(recursive: true);
        }
        return false;
      }

      // Atomic swap with rollback: backup current version, move staging to target,
      // and delete backup only on success.
      final oldApp = Directory(targetPath);
      final backupPath = '$targetPath.old';
      final backupDir = Directory(backupPath);
      if (await backupDir.exists()) {
        await backupDir.delete(recursive: true);
      }
      if (await oldApp.exists()) {
        await oldApp.rename(backupPath);
      }
      try {
        await stagingDir.rename(targetPath);
        if (await backupDir.exists()) {
          await backupDir.delete(recursive: true);
        }
      } catch (e) {
        _log.severe('Failed to rename staging to target, rolling back: $e');
        if (await backupDir.exists()) {
          await backupDir.rename(targetPath);
        }
        rethrow;
      }

      // Clean up the downloaded DMG.
      try {
        await File(dmgPath).delete();
      } catch (e, st) {
      LoggingService.logger('DesktopUpdateService').warning('Operation failed', e, st);
    }

      return true;
    } catch (e) {
      _log.severe('macOS update installation failed', e);
      return false;
    } finally {
      // Always detach the mounted volume, even on failure.
      if (mountPoint != null) {
        try {
          await Process.run('hdiutil', ['detach', mountPoint]);
        } catch (e) {
          _log.warning('Failed to detach DMG volume: $e');
        }
      }
    }
  }

  Future<bool> _verifyCodeSignature(String filePath) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('powershell', [
          '-Command',
          '(Get-AuthenticodeSignature "$filePath").Status',
        ]);
        return result.stdout.toString().trim() == 'Valid';
      } else if (Platform.isMacOS) {
        final result = await Process.run('codesign', [
          '--verify',
          '--deep',
          '--strict',
          filePath,
        ]);
        return result.exitCode == 0;
      } else if (Platform.isLinux) {
        final sigFile = '$filePath.sig';
        if (!await File(sigFile).exists()) {
          _log.severe(
              '[DesktopUpdateService] Linux update signature file missing ($sigFile) — rejecting unsigned update package');
          return false;
        }
        try {
          final gpgCheck = await Process.run('which', ['gpg']);
          if (gpgCheck.exitCode != 0) {
            _log.severe(
                '[DesktopUpdateService] GPG binary missing on Linux system — cannot verify update signature');
            return false;
          }
          final result = await Process.run('gpg', [
            '--verify',
            sigFile,
            filePath,
          ]);
          if (result.exitCode != 0) {
            _log.severe(
                '[DesktopUpdateService] GPG signature verification failed: ${result.stderr}');
            return false;
          }
          return true;
        } catch (e) {
          _log.severe(
              '[DesktopUpdateService] Failed to execute gpg verification on Linux: $e');
          return false;
        }
      }
    } catch (e) {
      _log.warning('Code signature verification failed: $e');
    }
    return false;
  }

  /// Streaming SHA-256 verification — reads the file in 1MB chunks instead
  /// of loading the entire file into memory. Prevents OOM on large update
  /// files (e.g., 500MB+ desktop installers).
  Future<bool> _verifySha256(String filePath, String expectedSha256) async {
    try {
      Digest? digest;
      final innerSink = ChunkedConversionSink<Digest>.withCallback((results) {
        digest = results.single;
      });
      final sink = sha256.startChunkedConversion(innerSink);
      final file = File(filePath);
      final raf = await file.open(mode: FileMode.read);
      try {
        const bufferSize = 1024 * 1024; // 1MB chunks
        while (true) {
          final bytes = await raf.read(bufferSize);
          if (bytes.isEmpty) break;
          sink.add(bytes);
        }
      } finally {
        await raf.close();
      }
      sink.close();
      if (digest == null) {
        throw StateError('SHA-256 computation produced no digest');
      }
      final actual = digest!.toString();
      return actual.toLowerCase() == expectedSha256.toLowerCase();
    } catch (e) {
      _log.warning('SHA-256 verification failed', e);
      return false;
    }
  }

  String _currentPlatform() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }
}
