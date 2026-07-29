import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/mixins/download_backup_mixin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadBackupMixin', () {
    late TestBackupProvider provider;
    late FakeDatabaseService databaseService;

    setUp(() {
      databaseService = FakeDatabaseService();
      provider = TestBackupProvider(
        tasks: <DownloadTask>[],
        databaseService: databaseService,
      );
    });

    test('round-trips encrypted backups with the correct password', () {
      final original = 'hello backup payload';
      final encrypted = provider.encryptBackup(original, 'secret');

      expect(encrypted, isNotEmpty);
      expect(provider.decryptBackup(encrypted, 'secret'), original);
    });

    test('rejects encrypted backups with the wrong password', () {
      final encrypted = provider.encryptBackup('payload', 'secret');

      expect(provider.decryptBackup(encrypted, 'wrong-password'), isNull);
    });

    test('rejects tampered encrypted payloads', () {
      final encrypted = provider.encryptBackup('payload', 'secret');
      final decoded = base64Decode(encrypted);
      final tamperedBytes = List<int>.from(decoded);
      tamperedBytes[tamperedBytes.length - 1] ^= 0x01;
      final tampered = base64Encode(tamperedBytes);

      expect(provider.decryptBackup(tampered, 'secret'), isNull);
    });

    test('decrypts legacy XDMCRYPT v1 payloads using XOR', () {
      final payload = 'legacy payload';
      final keyBytes = sha256.convert(utf8.encode('legacy-password')).bytes;
      final cipherBytes = List<int>.generate(
        payload.length,
        (index) =>
            payload.codeUnitAt(index) ^ keyBytes[index % keyBytes.length],
      );
      final legacy = utf8.encode('XDMCRYPT');
      final encoded = base64Encode([...legacy, ...cipherBytes]);

      expect(provider.decryptBackup(encoded, 'legacy-password'), payload);
    });

    test('exports and imports backups without a password', () async {
      provider.providerTasks.add(_sampleTask('one'));

      final export = provider.exportBackupJson();
      final importedProvider = TestBackupProvider(
        tasks: <DownloadTask>[],
        databaseService: FakeDatabaseService(),
      );

      final result = await importedProvider.importBackupJson(export);

      expect(result, isTrue);
      expect(importedProvider.providerTasks, hasLength(1));
      expect(importedProvider.providerTasks.first.id, 'one');
    });

    test('exports and imports backups with a password', () async {
      provider.providerTasks.add(_sampleTask('two'));

      final export = provider.exportBackupJson(password: 'secret');
      final importedProvider = TestBackupProvider(
        tasks: <DownloadTask>[],
        databaseService: FakeDatabaseService(),
      );

      final result = await importedProvider.importBackupJson(
        export,
        password: 'secret',
      );

      expect(result, isTrue);
      expect(importedProvider.providerTasks, hasLength(1));
      expect(importedProvider.providerTasks.first.id, 'two');
    });

    test('replace mode clears existing tasks before importing', () async {
      provider.providerTasks.add(_sampleTask('old'));

      provider.exportBackupJson();
      final incoming = _sampleTask('new');
      final incomingJson = jsonEncode([incoming.toMap()]);

      final importedProvider = TestBackupProvider(
        tasks: <DownloadTask>[_sampleTask('stale')],
        databaseService: databaseService,
      );

      final result = await importedProvider.importBackupJson(
        incomingJson,
        replace: true,
      );

      expect(result, isTrue);
      expect(importedProvider.providerTasks, hasLength(1));
      expect(importedProvider.providerTasks.single.id, 'new');
      expect(databaseService.clearCalls, 1);
    });
  });
}

DownloadTask _sampleTask(String id) {
  return DownloadTask(
    id: id,
    fileName: 'file-$id.mp4',
    url: 'https://example.com/$id',
    fileSize: 100,
    downloadedBytes: 10,
    category: 'Other',
    status: DownloadStatus.paused,
    savePath: '/downloads',
    localFilePath: '/downloads/$id.mp4',
    tempFilePath: '/downloads/$id.mp4.tmp',
    threadCount: 1,
    chunks: [0.1],
    createdAt: DateTime(2024, 1, 1),
    updatedAt: DateTime(2024, 1, 1),
  );
}

class TestBackupProvider with DownloadBackupMixin {
  TestBackupProvider({
    required List<DownloadTask> tasks,
    required this.databaseService,
  }) {
    providerTasks = tasks;
  }

  @override
  late final List<DownloadTask> providerTasks;

  final FakeDatabaseService databaseService;

  int notifyCount = 0;
  bool filteredTasksDirtyValue = false;

  @override
  void notifyListeners() {
    notifyCount++;
  }

  @override
  set filteredTasksDirty(bool value) {
    filteredTasksDirtyValue = value;
  }

  @override
  void updateTelemetryWidget() {}

  @override
  DatabaseService get providerDatabaseService => databaseService;
}

class FakeDatabaseService extends DatabaseService {
  int clearCalls = 0;
  final List<DownloadTask> savedTasks = <DownloadTask>[];

  @override
  Future<void> clearAllTasks() async {
    clearCalls++;
  }

  @override
  Future<void> saveTask(DownloadTask task) async {
    savedTasks.add(task);
  }
}
