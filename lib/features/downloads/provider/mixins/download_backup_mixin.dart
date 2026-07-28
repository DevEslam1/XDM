import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt_lib;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/services/database_service.dart';
import '../../../../core/utils/url_utils.dart';
import '../../models/download_task.dart';

/// Mixin that encapsulates backup export/import and encryption/decryption
/// logic for download tasks.
///
/// Requires the host class to expose:
///  - `List<DownloadTask> get providerTasks`
///  - `DatabaseService get providerDatabaseService`
///  - `void notifyListeners()`
///  - `set filteredTasksDirty(bool)`
///  - `void updateTelemetryWidget()`
mixin DownloadBackupMixin {
  // ---------------------------------------------------------------------------
  // Abstract contract — must be provided by the host class
  // ---------------------------------------------------------------------------
  List<DownloadTask> get providerTasks;
  DatabaseService get providerDatabaseService;
  void notifyListeners();
  set filteredTasksDirty(bool value);
  void updateTelemetryWidget();

  // ---------------------------------------------------------------------------
  // Encryption helpers
  // ---------------------------------------------------------------------------
  /// DEPRECATED: This legacy XOR cipher helper is insecure (XDMCRYPT v1 format).
  /// Kept solely for backwards compatibility to allow legacy imports. New backups
  /// must be encrypted with encryptBackup (AES-256).
  List<int> _xorCipher(List<int> data, List<int> key) {
    final List<int> result = List<int>.filled(data.length, 0);
    for (int i = 0; i < data.length; i++) {
      result[i] = data[i] ^ key[i % key.length];
    }
    return result;
  }

  String encryptBackup(String jsonStr, String password) {
    final keyBytes = sha256.convert(utf8.encode(password)).bytes;
    final key = encrypt_lib.Key(Uint8List.fromList(keyBytes));
    final iv = encrypt_lib.IV.fromSecureRandom(16);

    final encrypter = encrypt_lib.Encrypter(encrypt_lib.AES(key));
    final encrypted = encrypter.encrypt(jsonStr, iv: iv);

    final magic = utf8.encode('XDMCRYPT3');
    final payload = [...magic, ...iv.bytes, ...encrypted.bytes];
    final mac = Hmac(sha256, keyBytes).convert(payload).bytes;
    final finalBytes = [...payload, ...mac];
    return base64Encode(finalBytes);
  }

  String? decryptBackup(String encryptedBase64, String password) {
    try {
      final bytes = base64Decode(encryptedBase64);
      final authenticatedMagic = utf8.encode('XDMCRYPT3');
      final isAuthenticated =
          bytes.length >= authenticatedMagic.length &&
          _hasMagic(bytes, authenticatedMagic);
      final legacyMagic = utf8.encode('XDMCRYPT');

      bool isLegacy = !isAuthenticated && bytes.length >= legacyMagic.length;
      if (isLegacy) {
        for (int i = 0; i < legacyMagic.length; i++) {
          if (bytes[i] != legacyMagic[i]) {
            isLegacy = false;
            break;
          }
        }
      }

      if (isLegacy) {
        debugPrint('[XDM Security Warning] Decrypting legacy insecure XDMCRYPT v1 backup format using XOR cipher. Please re-export your backup to update to AES-GCM format.');
        final cipherBytes = bytes.sublist(legacyMagic.length);
        final keyBytes = sha256.convert(utf8.encode(password)).bytes;
        final dataBytes = _xorCipher(cipherBytes, keyBytes);
        return utf8.decode(dataBytes);
      }

      final magic = utf8.encode('XDMCRYPT2');
      if (!isAuthenticated && bytes.length < magic.length + 16) return null;
      if (!isAuthenticated && !_hasMagic(bytes, magic)) return null;

      if (isAuthenticated) {
        if (bytes.length < authenticatedMagic.length + 16 + 32) return null;
      }

      final payload = isAuthenticated
          ? bytes.sublist(0, bytes.length - 32)
          : bytes;
      if (isAuthenticated) {
        final keyBytes = sha256.convert(utf8.encode(password)).bytes;
        final expectedMac = Hmac(sha256, keyBytes).convert(payload).bytes;
        final actualMac = bytes.sublist(bytes.length - 32);
        if (!_constantTimeEquals(expectedMac, actualMac)) return null;
      }

      final header = isAuthenticated ? authenticatedMagic : magic;
      final ivBytes = payload.sublist(header.length, header.length + 16);
      final cipherBytes = payload.sublist(header.length + 16);

      final keyBytes = sha256.convert(utf8.encode(password)).bytes;
      final key = encrypt_lib.Key(Uint8List.fromList(keyBytes));
      final iv = encrypt_lib.IV(Uint8List.fromList(ivBytes));

      final encrypter = encrypt_lib.Encrypter(encrypt_lib.AES(key));
      final encrypted = encrypt_lib.Encrypted(Uint8List.fromList(cipherBytes));
      return encrypter.decrypt(encrypted, iv: iv);
    } catch (e) {
      return null;
    }
  }

  bool _hasMagic(List<int> bytes, List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  bool _constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var i = 0; i < left.length; i++) {
      difference |= left[i] ^ right[i];
    }
    return difference == 0;
  }

  // ---------------------------------------------------------------------------
  // Export / Import
  // ---------------------------------------------------------------------------
  String exportBackupJson({String? password}) {
    final list = providerTasks.map((t) => t.toMap()).toList();
    final jsonStr = jsonEncode(list);
    if (password != null && password.isNotEmpty) {
      return encryptBackup(jsonStr, password);
    }
    return jsonStr;
  }

  Future<bool> importBackupJson(
    String content, {
    bool replace = false,
    String? password,
  }) async {
    try {
      String jsonStr = content.trim();
      bool isEncrypted = false;
      try {
        final bytes = base64Decode(jsonStr);
        final magic = utf8.encode('XDMCRYPT');
        if (bytes.length >= magic.length) {
          isEncrypted = true;
          for (int i = 0; i < magic.length; i++) {
            if (bytes[i] != magic[i]) {
              isEncrypted = false;
              break;
            }
          }
        }
      } catch (_) {}

      if (isEncrypted) {
        if (password == null || password.isEmpty) {
          return false;
        }
        final decrypted = decryptBackup(jsonStr, password);
        if (decrypted == null) {
          return false;
        }
        jsonStr = decrypted;
      }

      final list = jsonDecode(jsonStr) as List;
      for (final item in list) {
        if (item is! Map) return false;
        if (!item.containsKey('id') ||
            !item.containsKey('url') ||
            !item.containsKey('fileName')) {
          return false;
        }
      }

      if (replace) {
        await providerDatabaseService.clearAllTasks();
        providerTasks.clear();
        filteredTasksDirty = true;
      }

      var hasChanges = false;
      for (final item in list) {
        final Map<String, dynamic> map = Map<String, dynamic>.from(item as Map);
        final task = DownloadTask.fromMap(map);
        if (!providerTasks.any((t) => t.id == task.id)) {
          providerTasks.add(task);
          filteredTasksDirty = true;
          await providerDatabaseService.saveTask(task);
          hasChanges = true;
        }
      }

      if (hasChanges || replace) {
        notifyListeners();
        updateTelemetryWidget();
      }
      return true;
    } catch (e) {
      debugPrint('Backup import error: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Import from other download managers
  // ---------------------------------------------------------------------------

  Future<int> importFromAria2(String filePath) async {
    int count = 0;
    try {
      final file = File(filePath);
      if (!await file.exists()) return 0;
      final lines = await file.readAsLines();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        final uri = Uri.tryParse(trimmed);
        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'magnet')) {
          final id = const Uuid().v4();
          final fileName = fileNameFromUrl(trimmed);
          final task = DownloadTask(
            id: id,
            url: trimmed,
            fileName: fileName,
            fileSize: 0,
            downloadedBytes: 0,
            category: 'Other',
            status: DownloadStatus.paused,
            savePath: '',
            localFilePath: '',
            tempFilePath: '',
            threadCount: 1,
            chunks: [0.0],
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );
          providerTasks.add(task);
          await providerDatabaseService.saveTask(task);
          count++;
        }
      }
      if (count > 0) {
        filteredTasksDirty = true;
        notifyListeners();
        updateTelemetryWidget();
      }
    } catch (e) {
      debugPrint('[DMX] Failed to import from aria2: $e');
    }
    return count;
  }

  Future<int> importFromIdm(String filePath) async {
    int count = 0;
    try {
      final file = File(filePath);
      if (!await file.exists()) return 0;
      final content = await file.readAsString();
      final urlRegex = RegExp(r'(https?://\S+)', caseSensitive: false);
      final matches = urlRegex.allMatches(content);
      for (final match in matches) {
        final url = match.group(1)!;
        final id = const Uuid().v4();
        final fileName = fileNameFromUrl(url);
        final task = DownloadTask(
          id: id,
          url: url,
          fileName: fileName,
          fileSize: 0,
          downloadedBytes: 0,
          category: 'Other',
          status: DownloadStatus.paused,
          savePath: '',
          localFilePath: '',
          tempFilePath: '',
          threadCount: 1,
          chunks: [0.0],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        providerTasks.add(task);
        await providerDatabaseService.saveTask(task);
        count++;
      }
      if (count > 0) {
        filteredTasksDirty = true;
        notifyListeners();
        updateTelemetryWidget();
      }
    } catch (e) {
      debugPrint('[DMX] Failed to import from IDM: $e');
    }
    return count;
  }

  Future<int> importFromJdownloader(String folderPath) async {
    int count = 0;
    try {
      final dir = Directory(folderPath);
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.crawljob')) {
          final content = await entity.readAsString();
          final urlMatch = RegExp(r'url\s*=\s*(\S+)', caseSensitive: false).firstMatch(content);
          if (urlMatch != null) {
            final url = urlMatch.group(1)!;
            final id = const Uuid().v4();
            final fileName = fileNameFromUrl(url);
            final task = DownloadTask(
              id: id,
              url: url,
              fileName: fileName,
              fileSize: 0,
              downloadedBytes: 0,
              category: 'Other',
              status: DownloadStatus.paused,
              savePath: '',
              localFilePath: '',
              tempFilePath: '',
              threadCount: 1,
              chunks: [0.0],
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            );
            providerTasks.add(task);
            await providerDatabaseService.saveTask(task);
            count++;
          }
        }
      }
      if (count > 0) {
        filteredTasksDirty = true;
        notifyListeners();
        updateTelemetryWidget();
      }
    } catch (e) {
      debugPrint('[DMX] Failed to import from JDownloader: $e');
    }
    return count;
  }
}

// TODO: Add unit tests for DownloadBackupMixin
//   - encryptBackup/decryptBackup: round-trip, wrong password, tampered data
//   - exportBackupJson/importBackupJson: with/without password, replace mode
//   - Legacy XDMCRYPT v1 format decryption
//   - Constant-time comparison correctness