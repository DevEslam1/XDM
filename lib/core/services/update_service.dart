import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:encrypt/encrypt.dart' as encrypt_lib;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/asymmetric/api.dart' show RSAPublicKey;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';

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

  // FIX(#5): Added structured logging
  static final _log = Logger('UpdateService');
  // FIX(#5): Secure storage instance for persisted public key
  static const _secureStorage = FlutterSecureStorage();
  // FIX(#5): Cached public key to avoid repeated storage reads
  static String? _publicKeyPem;

  static const String kDefaultUpdateManifestUrl =
      'https://raw.githubusercontent.com/DevEslam1/XDM/main/version_manifest.json';

  static const List<String> kUpdateManifestMirrors = [
    'https://cdn.jsdelivr.net/gh/DevEslam1/XDM@main/version_manifest.json',
  ];

  // FIX(#5): Load public key from multiple secure sources in priority order
  static Future<void> loadPublicKey() async {
    if (_publicKeyPem != null) return;

    // Priority 1: Compile-time define (Dart Environment)
    const envKey = String.fromEnvironment('DMX_UPDATE_PUBLIC_KEY');
    if (envKey.isNotEmpty) {
      _publicKeyPem = envKey;
      _log.info('Update signing key loaded from environment.');
      return;
    }

    // Priority 2: Secure storage (Provisioned via provisionPublicKey)
    try {
      final storedKey = await _secureStorage.read(key: 'dmx_update_pub_key');
      if (storedKey != null && storedKey.isNotEmpty) {
        _publicKeyPem = storedKey;
        _log.info('Update signing key loaded from secure storage.');
        return;
      }
    } catch (e) {
      _log.warning('Failed to read update key from secure storage: $e');
    }

    // Priority 3: No key available - FAIL CLOSED configuration
    _log.warning(
        'No update signing key configured. Updates will be rejected until a key is provisioned.');
  }

  // FIX(#5): Provision a new public key (admin only / first run)
  static Future<bool> provisionPublicKey(String pem) async {
    try {
      // Validate it's a real RSA public key before storing
      final parser = encrypt_lib.RSAKeyParser();
      final key = parser.parse(pem);
      if (key is! RSAPublicKey) {
        _log.severe(
            'Provisioning failed: Provided string is not an RSA public key.');
        return false;
      }

      await _secureStorage.write(key: 'dmx_update_pub_key', value: pem);
      _publicKeyPem = pem;
      _log.info('New update signing key provisioned successfully.');
      return true;
    } catch (e) {
      _log.severe('Key provisioning error: $e');
      return false;
    }
  }

  // FIX(#5): Defensive SHA-256 pinning check for manifest integrity
  static bool _verifyManifestHash(String rawJson) {
    const pinnedHash = String.fromEnvironment('DMX_UPDATE_MANIFEST_HASH');
    if (pinnedHash.isEmpty) return true; // Pinning not configured

    final actualHash = sha256.convert(utf8.encode(rawJson)).toString();
    if (actualHash.toLowerCase() != pinnedHash.toLowerCase()) {
      _log.severe('Manifest hash mismatch! Possible MITM or corruption.');
      return false;
    }
    return true;
  }

  /// Verifies an RSA-SHA256 signature over the canonical manifest JSON.
  /// Returns true only if the signature matches the loaded public key.
  static bool verifyManifestSignature(
    String canonicalJson,
    String signatureBase64,
  ) {
    // FIX(#5): FAIL CLOSED if no key is configured
    if (_publicKeyPem == null || _publicKeyPem!.trim().isEmpty) {
      _log.severe(
          'Cannot verify manifest: no public key configured. Check rejected.');
      return false;
    }

    try {
      final parser = encrypt_lib.RSAKeyParser();
      final publicKey = parser.parse(_publicKeyPem!) as RSAPublicKey;
      final signer = encrypt_lib.Signer(
        encrypt_lib.RSASigner(
          encrypt_lib.RSASignDigest.SHA256,
          publicKey: publicKey,
        ),
      );
      return signer.verify64(canonicalJson, signatureBase64);
    } catch (e) {
      _log.severe('Manifest signature verification error: $e');
      return false;
    }
  }

  /// Checks for an app update by downloading the update manifest JSON.
  /// Returns [UpdateInfo] if a newer version or mandatory update is available, null otherwise.
  Future<UpdateInfo?> checkForUpdate({String? manifestUrl}) async {
    // FIX(#5): Ensure public key is loaded before proceeding
    await loadPublicKey();

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

          final String rawData;
          if (response.data is String) {
            rawData = response.data as String;
          } else {
            rawData = jsonEncode(response.data);
          }

          // FIX(#5): Defense-in-depth hash pinning check
          if (!_verifyManifestHash(rawData)) continue;

          final Map<String, dynamic> json =
              await compute(_parseUpdateManifestJson, rawData);

          // FIX(#5): Enforce RSA signature check: manifests WITHOUT a valid signature are ALWAYS rejected.
          final signature = json['signature'] as String?;
          if (signature == null || signature.trim().isEmpty) {
            _log.severe('Update manifest has no signature. Rejecting $url');
            continue;
          }

          final canonical = jsonEncode(
            Map<String, dynamic>.from(json)..remove('signature'),
          );

          if (!verifyManifestSignature(canonical, signature.trim())) {
            _log.severe(
                'Manifest signature invalid for $url; rejecting version manifest.');
            continue;
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
            _log.warning('Update manifest not found (404): $url');
          } else {
            _log.warning('Failed to fetch manifest $url: $e');
          }
        } catch (e) {
          _log.severe('Failed to check update from $url: $e');
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
          _log.warning('File size mismatch: expected $expectedSize, got $size');
          return false;
        }
      }

      if (expectedSha256 != null && expectedSha256.trim().isNotEmpty) {
        final digest = await _computeSha256Streaming(apkFile);
        if (digest.toLowerCase() != expectedSha256.trim().toLowerCase()) {
          _log.severe('SHA256 mismatch');
          return false;
        }
      }
      return true;
    } catch (e) {
      _log.severe('Integrity check error: $e');
      return false;
    }
  }
}

/// Parses the update manifest JSON string.
Map<String, dynamic> _parseUpdateManifestJson(String rawData) {
  return jsonDecode(rawData) as Map<String, dynamic>;
}
