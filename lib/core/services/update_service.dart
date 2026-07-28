import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class UpdateInfo {
  final String latestVersion;
  final int versionCode;
  final String apkUrl;
  final String changelog;
  final bool mandatory;
  final int minSupportedVersionCode;
  final String? sha256;

  UpdateInfo({
    required this.latestVersion,
    required this.versionCode,
    required this.apkUrl,
    required this.changelog,
    required this.mandatory,
    required this.minSupportedVersionCode,
    this.sha256,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      latestVersion: json['latestVersion'] as String? ?? '1.0.0',
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      apkUrl: json['apkUrl'] as String? ?? '',
      changelog: json['changelog'] as String? ?? '',
      mandatory: json['mandatory'] as bool? ?? false,
      minSupportedVersionCode: (json['minSupportedVersionCode'] as num?)?.toInt() ?? 0,
      sha256: json['sha256'] as String?,
    );
  }
}

class UpdateService {
  UpdateService._();
  static final UpdateService _instance = UpdateService._();
  factory UpdateService() => _instance;

  static const String kDefaultUpdateManifestUrl =
      'https://raw.githubusercontent.com/DevEslam1/XDM/main/version_manifest.json';

  Dio? _dio;

  Dio _getDio() {
    _dio ??= Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
    return _dio!;
  }

  void dispose() {
    _dio?.close(force: true);
    _dio = null;
  }

  /// Checks for an app update by downloading the update manifest JSON.
  /// Returns [UpdateInfo] if a newer version or mandatory update is available, null otherwise.
  Future<UpdateInfo?> checkForUpdate({String? manifestUrl}) async {
    try {
      final url = manifestUrl ?? kDefaultUpdateManifestUrl;
      final response = await _getDio().get<dynamic>(url);
      if (response.statusCode == 200 && response.data != null) {
        final Map<String, dynamic> json;
        if (response.data is String) {
          json = Map<String, dynamic>.from(jsonDecode(response.data as String));
        } else if (response.data is Map) {
          json = Map<String, dynamic>.from(response.data as Map);
        } else {
          return null;
        }

        final update = UpdateInfo.fromJson(json);
        final packageInfo = await PackageInfo.fromPlatform();
        final currentVersionCode = int.tryParse(packageInfo.buildNumber) ?? 0;

        if (update.versionCode > currentVersionCode ||
            currentVersionCode < update.minSupportedVersionCode) {
          return update;
        }
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        debugPrint('[UpdateService] Update manifest not found (404).');
      } else {
        debugPrint('[UpdateService] Failed to check for update: $e');
      }
    } catch (e) {
      debugPrint('[UpdateService] Failed to check for update: $e');
    }
    return null;
  }

  /// Computes SHA-256 hash of a file using streaming to avoid loading entire file into memory.
  Future<String> _computeSha256Streaming(File file) async {
    Digest? digest;
    final innerSink = ChunkedConversionSink<Digest>.withCallback((results) {
      digest = results.single;
    });
    final sink = sha256.startChunkedConversion(innerSink);
    final stream = file.openRead();
    await for (final chunk in stream) {
      sink.add(chunk);
    }
    sink.close();
    return digest.toString();
  }

  /// Dedicated local folder for storing downloaded app update APKs.
  Future<Directory> getUpdatesDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    final updatesDir = Directory('${supportDir.path}/app_updates');
    if (!await updatesDir.exists()) {
      await updatesDir.create(recursive: true);
    }
    return updatesDir;
  }

  /// Basic file integrity verification (file size and optional SHA-256 hash).
  Future<bool> verifyApkIntegrity(File apkFile, {int? expectedSize, String? expectedSha256}) async {
    try {
      if (!await apkFile.exists()) return false;
      if (expectedSize != null && expectedSize > 0) {
        final size = await apkFile.length();
        if (size != expectedSize) {
          debugPrint('[UpdateService] File size mismatch: expected $expectedSize, got $size');
          return false;
        }
      }

      if (expectedSha256 != null && expectedSha256.trim().isNotEmpty) {
        final digest = await _computeSha256Streaming(apkFile);
        if (digest.toLowerCase() != expectedSha256.trim().toLowerCase()) {
          debugPrint('[UpdateService] SHA256 mismatch');
          return false;
        }
      }
      return true;
    } catch (e) {
      debugPrint('[UpdateService] Integrity check error: $e');
      return false;
    }
  }
}
