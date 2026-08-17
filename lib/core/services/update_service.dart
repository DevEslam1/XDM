import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:encrypt/encrypt.dart' as encrypt_lib;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/asymmetric/api.dart' show RSAPublicKey;
import 'package:shared_preferences/shared_preferences.dart';

class UpdateInfo {
  final String latestVersion;
  final int versionCode;
  final String apkUrl;
  final String changelog;
  final bool mandatory;
  final int minSupportedVersionCode;
  final String? sha256;
  final String? expectedCertFingerprint;
  final String? packageName;

  UpdateInfo({
    required this.latestVersion,
    required this.versionCode,
    required this.apkUrl,
    required this.changelog,
    required this.mandatory,
    required this.minSupportedVersionCode,
    this.sha256,
    this.expectedCertFingerprint,
    this.packageName,
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
      expectedCertFingerprint: json['expectedCertFingerprint'] as String?,
      packageName: json['packageName'] as String?,
    );
  }
}

class ApkVerificationResult {
  final bool isValid;
  final String? certificateFingerprint;
  final String? expectedFingerprint;
  final String? packageName;
  final int? versionCode;
  final String? failureReason;
  final bool isDeveloperOverride;

  const ApkVerificationResult({
    required this.isValid,
    this.certificateFingerprint,
    this.expectedFingerprint,
    this.packageName,
    this.versionCode,
    this.failureReason,
    this.isDeveloperOverride = false,
  });

  @override
  String toString() =>
      'ApkVerificationResult(isValid: $isValid, fingerprint: $certificateFingerprint, reason: $failureReason, devOverride: $isDeveloperOverride)';
}

class UpdateService {
  UpdateService._();
  static final UpdateService _instance = UpdateService._();
  factory UpdateService() => _instance;

  static final _log = Logger('UpdateService');
  static const _secureStorage = FlutterSecureStorage();
  static String? _publicKeyPem;

  static const String kDefaultUpdateManifestUrl =
      'https://raw.githubusercontent.com/DevEslam1/XDM/main/version_manifest.json';

  static const List<String> kUpdateManifestMirrors = [
    'https://cdn.jsdelivr.net/gh/DevEslam1/XDM@main/version_manifest.json',
    'https://fastly.jsdelivr.net/gh/DevEslam1/XDM@main/version_manifest.json',
  ];

  static Future<void> loadPublicKey() async {
    if (_publicKeyPem != null) return;

    const envKey = String.fromEnvironment('DMX_UPDATE_PUBLIC_KEY');
    if (envKey.isNotEmpty) {
      _publicKeyPem = envKey;
      _log.info('Update signing key loaded from environment.');
      return;
    }

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

    _log.warning(
        'No update signing key configured. Updates will be rejected until a key is provisioned.');
  }

  static Future<bool> provisionPublicKey(String pem) async {
    try {
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

  static bool _verifyManifestHash(String rawJson) {
    const pinnedHash = String.fromEnvironment('DMX_UPDATE_MANIFEST_HASH');
    if (pinnedHash.isEmpty) return true;

    final actualHash = sha256.convert(utf8.encode(rawJson)).toString();
    if (actualHash.toLowerCase() != pinnedHash.toLowerCase()) {
      _log.severe('Manifest hash mismatch! Possible MITM or corruption.');
      return false;
    }
    return true;
  }

  static bool verifyManifestSignature(
    String canonicalJson,
    String signatureBase64,
  ) {
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

  Future<UpdateInfo?> checkForUpdate({String? manifestUrl}) async {
    // FIX #8: Check cooldown in SharedPreferences first
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastFailureMs = prefs.getInt('dmx_update_last_failure_time') ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastFailureMs < const Duration(hours: 1).inMilliseconds) {
        _log.info(
            'Skipping update check: within 1 hour cooldown after a failure.');
        return null;
      }
    } catch (e) {
      _log.warning(
          'Failed to check update cooldown from SharedPreferences: $e');
    }

    await loadPublicKey();

    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(
            seconds: 30), // FIX #8: Increase receiveTimeout to 30s
      ),
    );

    final primary = manifestUrl ?? kDefaultUpdateManifestUrl;
    final sources = <String>[primary, ...kUpdateManifestMirrors];
    if (manifestUrl != null) sources.removeWhere((s) => s == primary);

    bool checkSucceeded = false;
    int backoffDelaySeconds = 2;

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

          if (!_verifyManifestHash(rawData)) continue;

          final Map<String, dynamic> json =
              await compute(_parseUpdateManifestJson, rawData);

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

          checkSucceeded = true;
          // Clear failure cooldown on success
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove('dmx_update_last_failure_time');
            await prefs.setInt('dmx_update_last_success_time',
                DateTime.now().millisecondsSinceEpoch);
          } catch (_) {}

          if (update.versionCode > currentVersionCode ||
              currentVersionCode < update.minSupportedVersionCode) {
            return update;
          }
        } on DioException catch (e) {
          if (e.response?.statusCode == 404) {
            _log.warning('Update manifest not found (404): $url');
          } else if (e.response?.statusCode == 429) {
            _log.warning(
                'Rate limited (429) on $url. Applying backoff of ${backoffDelaySeconds}s.');
            // FIX #8: Exponential backoff on 429 rate limit
            await Future.delayed(Duration(seconds: backoffDelaySeconds));
            backoffDelaySeconds *= 2;
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

    if (!checkSucceeded) {
      // FIX #8: Cache failure check timestamp to skip for 1 hour
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('dmx_update_last_failure_time',
            DateTime.now().millisecondsSinceEpoch);
        _log.info('Update check failed. Cooldown of 1 hour applied.');
      } catch (e) {
        _log.warning(
            'Failed to save update failure time to SharedPreferences: $e');
      }
    }

    return null;
  }

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

  Future<Directory> getUpdatesDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    final updatesDir = Directory('${supportDir.path}/app_updates');
    if (!await updatesDir.exists()) {
      await updatesDir.create(recursive: true);
    }
    return updatesDir;
  }

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

  static const MethodChannel _securityChannel =
      MethodChannel('com.dmx.app/security');

  /// Complete APK Signature and Integrity Verification (SEC-06).
  Future<ApkVerificationResult> verifyApkSignature(
    File apkFile, {
    String? expectedFingerprint,
    String? expectedPackageName,
    int? minVersionCode,
    bool developerMode = false,
  }) async {
    try {
      if (!await apkFile.exists()) {
        return const ApkVerificationResult(
          isValid: false,
          failureReason: 'APK file does not exist',
        );
      }

      // L4/H22: Stream the header check instead of buffering the whole APK.
      final raf = await apkFile.open(mode: FileMode.read);
      try {
        final header = await raf.read(4);
        if (header.length < 4 ||
            header[0] != 0x50 ||
            header[1] != 0x4B ||
            header[2] != 0x03 ||
            header[3] != 0x04) {
          return const ApkVerificationResult(
            isValid: false,
            failureReason: 'Invalid zip/APK file signature header',
          );
        }
      } finally {
        await raf.close();
      }

      String? certFingerprint;
      try {
        certFingerprint = await _securityChannel.invokeMethod<String>(
          'verifyApkSignature',
          {'path': apkFile.path},
        );
      } on MissingPluginException {
        _log.warning(
            'Security channel unavailable for APK signature verification');
      } catch (e) {
        _log.warning('Security channel verification exception: $e');
      }

      if (developerMode) {
        _log.warning(
            'Developer mode bypass active: skipping certificate fingerprint check');
        return ApkVerificationResult(
          isValid: true,
          certificateFingerprint: certFingerprint,
          expectedFingerprint: expectedFingerprint,
          isDeveloperOverride: true,
        );
      }

      if (expectedFingerprint != null && expectedFingerprint.isNotEmpty) {
        if (certFingerprint == null) {
          return const ApkVerificationResult(
            isValid: false,
            failureReason: 'Native signature verification unavailable',
          );
        }
        if (certFingerprint.toLowerCase() !=
            expectedFingerprint.trim().toLowerCase()) {
          try {
            await apkFile.delete();
          } catch (e, st) {
            LoggingService.logger('UpdateService')
                .warning('Operation failed', e, st);
          }
          return ApkVerificationResult(
            isValid: false,
            certificateFingerprint: certFingerprint,
            expectedFingerprint: expectedFingerprint,
            failureReason: 'Certificate fingerprint mismatch',
          );
        }
      }

      return ApkVerificationResult(
        isValid: true,
        certificateFingerprint: certFingerprint,
        expectedFingerprint: expectedFingerprint,
      );
    } catch (e) {
      return ApkVerificationResult(
        isValid: false,
        failureReason: 'APK verification exception: $e',
      );
    }
  }
}

Map<String, dynamic> _parseUpdateManifestJson(String rawData) {
  return jsonDecode(rawData) as Map<String, dynamic>;
}
