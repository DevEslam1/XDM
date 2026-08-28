import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:encrypt/encrypt.dart' as encrypt_lib;
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:pointycastle/export.dart';
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
  /// Derives a 256-bit key from [password] and [salt] using PBKDF2-HMAC-SHA256.
  /// 100k iterations makes brute-force cost ~hours per guess instead of instant.
  List<int> _deriveKey(String password, List<int> salt) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(
        Uint8List.fromList(salt),
        100000,
        32,
      ));
    return pbkdf2.process(Uint8List.fromList(utf8.encode(password)));
  }

  List<int> _secureRandomBytes(int length) {
    final rng = Random.secure();
    return List<int>.generate(length, (_) => rng.nextInt(256));
  }

  /// Encrypts [jsonStr] as XDMCRYPT4 (AES-256-CBC + HMAC-SHA256,
  /// PBKDF2-derived key with random per-backup salt):
  ///
  ///   [XDMCRYPT4][salt 16][iv 16][ciphertext][hmac 32]
  ///
  /// The salt is stored alongside the ciphertext so decryptBackup can
  /// re-derive the same key.
  String encryptBackup(String jsonStr, String password) {
    final salt = _secureRandomBytes(16);
    final keyBytes = _deriveKey(password, salt);
    final key = encrypt_lib.Key(Uint8List.fromList(keyBytes));
    final iv = encrypt_lib.IV.fromSecureRandom(16);

    final encrypter = encrypt_lib.Encrypter(encrypt_lib.AES(key));
    final encrypted = encrypter.encrypt(jsonStr, iv: iv);

    final magic = utf8.encode('XDMCRYPT4');
    final payload = [...magic, ...salt, ...iv.bytes, ...encrypted.bytes];
    final mac = Hmac(sha256, keyBytes).convert(payload).bytes;
    final finalBytes = [...payload, ...mac];
    return base64Encode(finalBytes);
  }

  String? decryptBackup(String encryptedBase64, String password) {
    try {
      final bytes = base64Decode(encryptedBase64);
      final v4Magic = utf8.encode('XDMCRYPT4');
      if (_hasMagic(bytes, v4Magic)) {
        // XDMCRYPT4 (PBKDF2): [magic][salt 16][iv 16][ciphertext][hmac 32]
        final saltStart = v4Magic.length;
        final ivStart = saltStart + 16;
        final keyBytes =
            _deriveKey(password, bytes.sublist(saltStart, ivStart));
        final payload = bytes.sublist(0, bytes.length - 32);
        final expectedMac = Hmac(sha256, keyBytes).convert(payload).bytes;
        final actualMac = bytes.sublist(bytes.length - 32);
        if (!_constantTimeEquals(expectedMac, actualMac)) return null;

        final ivBytes = payload.sublist(ivStart, ivStart + 16);
        final cipherBytes = payload.sublist(ivStart + 16);
        final encrypter = encrypt_lib.Encrypter(encrypt_lib.AES(encrypt_lib.Key(
          Uint8List.fromList(keyBytes),
        )));
        final encrypted =
            encrypt_lib.Encrypted(Uint8List.fromList(cipherBytes));
        return encrypter.decrypt(
          encrypted,
          iv: encrypt_lib.IV(Uint8List.fromList(ivBytes)),
        );
      }

      final authenticatedMagic = utf8.encode('XDMCRYPT3');
      final isAuthenticated = bytes.length >= authenticatedMagic.length &&
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
        debugPrint(
          '[XDM Security Warning] Legacy insecure XDMCRYPT v1 backup format (XOR cipher) is no longer supported. Please create a new backup.',
        );
        return null;
      }

      final magic = utf8.encode('XDMCRYPT2');
      if (!isAuthenticated && bytes.length < magic.length + 16) return null;
      if (!isAuthenticated && !_hasMagic(bytes, magic)) return null;

      if (isAuthenticated) {
        if (bytes.length < authenticatedMagic.length + 16 + 32) return null;
      }

      final payload =
          isAuthenticated ? bytes.sublist(0, bytes.length - 32) : bytes;
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
    } catch (e, st) {
      LoggingService.logger('DownloadBackupMixin')
          .warning('Operation failed with fallback', e, st);
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
    final tasksJson = jsonEncode(list);
    final checksum = sha256.convert(utf8.encode(tasksJson)).toString();
    final envelope = {
      'version': 2,
      'checksum': checksum,
      'exportedAt': DateTime.now().toIso8601String(),
      'tasks': list,
    };
    final jsonStr = jsonEncode(envelope);
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
      if (content.length > 50 * 1024 * 1024) {
        debugPrint('[Backup Import] Payload exceeds maximum size of 50MB');
        return false;
      }

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
      } catch (e, st) {
        Logger('download_backup_mixin')
            .warning('[download_backup_mixin] operation failed', e, st);
      }

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

      final decoded = jsonDecode(jsonStr);
      final List list;
      if (decoded is Map && decoded.containsKey('tasks')) {
        // v2 Envelope format
        final tasks = decoded['tasks'] as List;
        final expectedChecksum = decoded['checksum'] as String?;
        if (expectedChecksum != null && expectedChecksum.isNotEmpty) {
          final tasksJson = jsonEncode(tasks);
          final actualChecksum =
              sha256.convert(utf8.encode(tasksJson)).toString();
          if (actualChecksum != expectedChecksum) {
            debugPrint(
              '[Backup Checksum Error] Expected $expectedChecksum, got $actualChecksum',
            );
            return false;
          }
        }
        list = tasks;
      } else if (decoded is List) {
        // Legacy v1 bare array format
        list = decoded;
      } else {
        return false;
      }

      if (list.length > 10000) {
        debugPrint('[Backup Import] Task list exceeds maximum count of 10000');
        return false;
      }

      for (final item in list) {
        if (item is! Map) return false;
        if (!item.containsKey('id') ||
            !item.containsKey('url') ||
            !item.containsKey('fileName')) {
          return false;
        }
        final id = item['id'];
        final url = item['url'];
        final fileName = item['fileName'];
        if (id is! String || id.isEmpty || id.length > 256) return false;
        if (url is! String || url.isEmpty || url.length > 4096) return false;
        if (fileName is! String || fileName.isEmpty || fileName.length > 512) {
          return false;
        }
      }
      final newTasks = <DownloadTask>[];
      for (final item in list) {
        final Map<String, dynamic> map = Map<String, dynamic>.from(item as Map);
        var task = DownloadTask.fromMap(map);
        // C6: Coerce exported active tasks to paused to prevent zombie live downloads
        if (task.status == DownloadStatus.downloading ||
            task.status == DownloadStatus.queued ||
            task.status == DownloadStatus.merging) {
          task = task.copyWith(
            status: DownloadStatus.paused,
            speed: 0,
            clearEta: true,
            pausedByUser: true,
          );
        }
        if (replace || !providerTasks.any((t) => t.id == task.id)) {
          newTasks.add(task);
        }
      }

      if (newTasks.isNotEmpty) {
        // NEW-4: Chunk DB writes in batches of 200 to prevent SQLite statement size overflow and RAM spikes
        const batchSize = 200;
        for (var i = 0; i < newTasks.length; i += batchSize) {
          final end = (i + batchSize < newTasks.length)
              ? i + batchSize
              : newTasks.length;
          final chunk = newTasks.sublist(i, end);
          await providerDatabaseService.saveTasks(chunk);
          if (newTasks.length > 500) {
            await Future<void>.delayed(
                Duration.zero); // yield event loop for UI fluidity
          }
        }

        if (replace) {
          final oldTaskIds = providerTasks.map((t) => t.id).toSet();
          final newTaskIds = newTasks.map((t) => t.id).toSet();
          final toRemoveIds = oldTaskIds.difference(newTaskIds);

          providerTasks
            ..clear()
            ..addAll(newTasks);

          for (final id in toRemoveIds) {
            await providerDatabaseService.deleteTask(id);
          }
        } else {
          final existingIds = providerTasks.map((t) => t.id).toSet();
          for (final task in newTasks) {
            if (!existingIds.contains(task.id)) {
              providerTasks.add(task);
            }
          }
        }

        filteredTasksDirty = true;
        notifyListeners();
        updateTelemetryWidget();
      } else if (replace) {
        // If importing empty list with replace=true
        final oldTaskIds = providerTasks.map((t) => t.id).toList();
        providerTasks.clear();
        for (final id in oldTaskIds) {
          await providerDatabaseService.deleteTask(id);
        }
        filteredTasksDirty = true;
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

  Future<int> importFromAria2(String inputPath) async {
    try {
      final file = File(inputPath);
      if (!await file.exists()) return 0;
      final lines = await file.readAsLines();
      final newTasks = <DownloadTask>[];
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        final url = trimmed.split('\t').first.trim();
        if (url.startsWith('http://') || url.startsWith('https://')) {
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
          newTasks.add(task);
        }
      }
      if (newTasks.isNotEmpty) {
        providerTasks.addAll(newTasks);
        await providerDatabaseService.saveTasks(newTasks);
        filteredTasksDirty = true;
        notifyListeners();
        updateTelemetryWidget();
      }
      return newTasks.length;
    } catch (e) {
      debugPrint('[DMX] Failed to import from aria2: $e');
      return 0;
    }
  }

  Future<int> importFromIdm(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return 0;
      final content = await file.readAsString();
      final urlRegex = RegExp(r'(https?://\S+)', caseSensitive: false);
      final matches = urlRegex.allMatches(content);
      final newTasks = <DownloadTask>[];
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
        newTasks.add(task);
      }
      if (newTasks.isNotEmpty) {
        providerTasks.addAll(newTasks);
        await providerDatabaseService.saveTasks(newTasks);
        filteredTasksDirty = true;
        notifyListeners();
        updateTelemetryWidget();
      }
      return newTasks.length;
    } catch (e) {
      debugPrint('[DMX] Failed to import from IDM: $e');
      return 0;
    }
  }

  Future<int> importFromJdownloader(String folderPath) async {
    try {
      final dir = Directory(folderPath);
      if (!await dir.exists()) return 0;
      final newTasks = <DownloadTask>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.crawljob')) {
          final content = await entity.readAsString();
          final urlMatch = RegExp(
            r'url\s*=\s*(\S+)',
            caseSensitive: false,
          ).firstMatch(content);
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
            newTasks.add(task);
          }
        }
      }
      if (newTasks.isNotEmpty) {
        providerTasks.addAll(newTasks);
        await providerDatabaseService.saveTasks(newTasks);
        filteredTasksDirty = true;
        notifyListeners();
        updateTelemetryWidget();
      }
      return newTasks.length;
    } catch (e) {
      debugPrint('[DMX] Failed to import from JDownloader: $e');
      return 0;
    }
  }
}
