import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
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
          } catch (_) {}
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
        } catch (_) {}
        return false;
      }

      if (Platform.isWindows) {
        final result = await Process.start(downloadPath, ['/S']);
        return result.pid > 0;
      } else if (Platform.isMacOS) {
        final mountResult =
            await Process.run('hdiutil', ['attach', downloadPath]);
        return mountResult.exitCode == 0;
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
        if (!await File(sigFile).exists()) return true;
        final result = await Process.run('gpg', [
          '--verify',
          sigFile,
          filePath,
        ]);
        return result.exitCode == 0;
      }
    } catch (e) {
      _log.warning('Code signature verification failed: $e');
    }
    return false;
  }

  Future<bool> _verifySha256(String filePath, String expectedSha256) async {
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      final digest = sha256.convert(bytes);
      return digest.toString().toLowerCase() == expectedSha256.toLowerCase();
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
