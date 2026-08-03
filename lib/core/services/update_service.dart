import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:encrypt/encrypt.dart' as encrypt_lib;
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/asymmetric/api.dart' show RSAPublicKey;

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
      minSupportedVersionCode:
          (json['minSupportedVersionCode'] as num?)?.toInt() ?? 0,
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

  /// FIX(26): fallback sources for the update manifest, tried in order when
  /// the primary source is unavailable.
  static const List<String> kUpdateManifestMirrors = [
    'https://cdn.jsdelivr.net/gh/DevEslam1/XDM@main/version_manifest.json',
  ];

  /// FIX(26): PEM public key used to verify the manifest signature. This is a
  /// placeholder — generate an RSA keypair, publish the public key here, and
  /// sign `version_manifest.json` (canonical JSON without the `signature`
  /// field) with the private key, embedding the base64 signature in the
  /// manifest's `signature` field.
  ///
  /// Manifests WITHOUT a `signature` field are still accepted for backward
  /// compatibility; once a real key is configured, signed manifests are
  /// verified and forged/tampered ones are rejected.
  static const String kUpdateManifestPublicKeyPem = '';

  /// Verifies an RSA-SHA256 signature over the canonical manifest JSON.
  /// Returns true only if the signature matches the bundled public key.
  static bool verifyManifestSignature(
    String canonicalJson,
    String signatureBase64,
  ) {
    if (kUpdateManifestPublicKeyPem.trim().isEmpty) {
      debugPrint(
        '[UpdateService] No public key configured; rejecting signed manifest.',
      );
      return false;
    }
    try {
      final parser = encrypt_lib.RSAKeyParser();
      final publicKey = parser.parse(
        kUpdateManifestPublicKeyPem,
      ) as RSAPublicKey;
      final signer = encrypt_lib.Signer(
        encrypt_lib.RSASigner(
          encrypt_lib.RSASignDigest.SHA256,
          publicKey: publicKey,
        ),
      );
      return signer.verify64(canonicalJson, signatureBase64);
    } catch (e) {
      debugPrint('[UpdateService] Manifest signature verification error: $e');
      return false;
    }
  }

  /// Checks for an app update by downloading the update manifest JSON.
  /// Returns [UpdateInfo] if a newer version or mandatory update is available, null otherwise.
  Future<UpdateInfo?> checkForUpdate({String? manifestUrl}) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );

    final primary = manifestUrl ?? kDefaultUpdateManifestUrl;
    final sources = <String>[primary, ...kUpdateManifestMirrors];
    if (manifestUrl != null) sources.removeWhere((s) => s == primary);

    try {
      for (final url in sources) {
        try {
          final response = await dio.get<dynamic>(url);
          if (response.statusCode != 200 || response.data == null) continue;
          final Map<String, dynamic> json;
          if (response.data is String) {
            json = Map<String, dynamic>.from(
              jsonDecode(response.data as String),
            );
          } else if (response.data is Map) {
            json = Map<String, dynamic>.from(response.data as Map);
          } else {
            continue;
          }

          // FIX(26): if the manifest carries a signature, it must verify
          // against the bundled public key — otherwise the source is skipped.
          final signature = json['signature'] as String?;
          if (signature != null && signature.trim().isNotEmpty) {
            final canonical = jsonEncode(
              Map<String, dynamic>.from(json)..remove('signature'),
            );
            if (!verifyManifestSignature(canonical, signature.trim())) {
              debugPrint(
                '[UpdateService] Manifest signature invalid for $url; '
                'trying next source.',
              );
              continue;
            }
          }

          final update = UpdateInfo.fromJson(json);
          final packageInfo = await PackageInfo.fromPlatform();
          final currentVersionCode = int.tryParse(packageInfo.buildNumber) ?? 0;

          if (update.versionCode > currentVersionCode ||
              currentVersionCode < update.minSupportedVersionCode) {
            return update;
          }
        } on DioException catch (e) {
          if (e.response?.statusCode == 404) {
            debugPrint('[UpdateService] Update manifest not found (404): $url');
          } else {
            debugPrint('[UpdateService] Failed to fetch manifest $url: $e');
          }
        } catch (e) {
          debugPrint('[UpdateService] Failed to check update from $url: $e');
        }
      }
    } finally {
      dio.close(force: true);
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
  Future<bool> verifyApkIntegrity(
    File apkFile, {
    int? expectedSize,
    String? expectedSha256,
  }) async {
    try {
      if (!await apkFile.exists()) return false;
      if (expectedSize != null && expectedSize > 0) {
        final size = await apkFile.length();
        if (size != expectedSize) {
          debugPrint(
            '[UpdateService] File size mismatch: expected $expectedSize, got $size',
          );
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
