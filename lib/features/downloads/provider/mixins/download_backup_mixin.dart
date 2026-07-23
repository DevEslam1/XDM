import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt_lib;
import 'package:flutter/foundation.dart';

import '../../../../core/services/database_service.dart';
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

      final payload = isAuthenticated
          ? bytes.sublist(0, bytes.length - 32)
          : bytes;
      if (isAuthenticated) {
        if (bytes.length < authenticatedMagic.length + 16 + 32) return null;
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
}
