import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt_lib;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:uuid/uuid.dart';

import '../../../core/services/database_service.dart';
import '../../../core/services/logging_service.dart';
import '../../../core/utils/url_utils.dart';
import '../models/download_task.dart';

/// Standalone domain service for backup creation, restoration, encryption, and third-party imports.
class DownloadBackupService {
  final DatabaseService _databaseService;
  static final _log = LoggingService.logger('DownloadBackupService');

  DownloadBackupService({DatabaseService? databaseService})
      : _databaseService = databaseService ?? DatabaseService.instance;

  DatabaseService get databaseService => _databaseService;

  /// Derives a 256-bit key from [password] and [salt] using PBKDF2-HMAC-SHA256.
  List<int> deriveKey(String password, List<int> salt) {
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

  /// Encrypts [jsonStr] as XDMCRYPT4 (AES-256-CBC + HMAC-SHA256).
  String encryptBackup(String jsonStr, String password) {
    final salt = _secureRandomBytes(16);
    final keyBytes = deriveKey(password, salt);
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
        final saltStart = v4Magic.length;
        final ivStart = saltStart + 16;
        final keyBytes = deriveKey(password, bytes.sublist(saltStart, ivStart));
        final payload = bytes.sublist(0, bytes.length - 32);
        final expectedMac = Hmac(sha256, keyBytes).convert(payload).bytes;
        final actualMac = bytes.sublist(bytes.length - 32);
        if (!_constantTimeEquals(expectedMac, actualMac)) return null;

        final ivBytes = payload.sublist(ivStart, ivStart + 16);
        final cipherBytes = payload.sublist(ivStart + 16);
        final encrypter = encrypt_lib.Encrypter(encrypt_lib.AES(encrypt_lib.Key(
          Uint8List.fromList(keyBytes),
        )));
        final encrypted = encrypt_lib.Encrypted(Uint8List.fromList(cipherBytes));
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
          '[XDM Security Warning] Legacy insecure XDMCRYPT v1 backup format is no longer supported.',
        );
        return null;
      }

      final magic = utf8.encode('XDMCRYPT2');
      if (!isAuthenticated && bytes.length < magic.length + 16) return null;
      if (!isAuthenticated && !_hasMagic(bytes, magic)) return null;

      if (isAuthenticated && bytes.length < authenticatedMagic.length + 16 + 32) {
        return null;
      }

      final payload = isAuthenticated ? bytes.sublist(0, bytes.length - 32) : bytes;
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
      _log.warning('Decrypt backup failed', e, st);
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

  /// Exports tasks to serialized JSON envelope or encrypted string.
  String exportBackupJson(List<DownloadTask> tasks, {String? password}) {
    final list = tasks.map((t) => t.toMap()).toList();
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

  /// Parses and validates backup JSON string.
  List<DownloadTask>? parseBackupContent(String content, {String? password}) {
    try {
      if (content.length > 50 * 1024 * 1024) return null;

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
        if (password == null || password.isEmpty) return null;
        final decrypted = decryptBackup(jsonStr, password);
        if (decrypted == null) return null;
        jsonStr = decrypted;
      }

      final decoded = jsonDecode(jsonStr);
      final List list;
      if (decoded is Map && decoded.containsKey('tasks')) {
        final tasks = decoded['tasks'] as List;
        final expectedChecksum = decoded['checksum'] as String?;
        if (expectedChecksum != null && expectedChecksum.isNotEmpty) {
          final tasksJson = jsonEncode(tasks);
          final actualChecksum = sha256.convert(utf8.encode(tasksJson)).toString();
          if (actualChecksum != expectedChecksum) return null;
        }
        list = tasks;
      } else if (decoded is List) {
        list = decoded;
      } else {
        return null;
      }

      if (list.length > 10000) return null;

      final parsed = <DownloadTask>[];
      for (final item in list) {
        if (item is! Map) return null;
        if (!item.containsKey('id') || !item.containsKey('url') || !item.containsKey('fileName')) {
          return null;
        }
        final Map<String, dynamic> map = Map<String, dynamic>.from(item);
        var task = DownloadTask.fromMap(map);
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
        parsed.add(task);
      }
      return parsed;
    } catch (e, st) {
      _log.warning('parseBackupContent failed', e, st);
      return null;
    }
  }

  Future<List<DownloadTask>> importFromAria2(String inputPath) async {
    final file = File(inputPath);
    if (!await file.exists()) return [];
    final lines = await file.readAsLines();
    final newTasks = <DownloadTask>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final url = trimmed.split('\t').first.trim();
      if (url.startsWith('http://') || url.startsWith('https://')) {
        final id = const Uuid().v4();
        final fileName = fileNameFromUrl(url);
        newTasks.add(DownloadTask(
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
          chunks: const [0.0],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ));
      }
    }
    return newTasks;
  }

  Future<List<DownloadTask>> importFromIdm(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return [];
    final content = await file.readAsString();
    final urlRegex = RegExp(r'(https?://\S+)', caseSensitive: false);
    final matches = urlRegex.allMatches(content);
    final newTasks = <DownloadTask>[];
    for (final match in matches) {
      final url = match.group(1)!;
      final id = const Uuid().v4();
      final fileName = fileNameFromUrl(url);
      newTasks.add(DownloadTask(
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
        chunks: const [0.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
    }
    return newTasks;
  }
}
