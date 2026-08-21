import 'dart:io';
import 'package:dmx/core/services/download_journal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('unified_wal_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('Unified WAL: snapshot-only rebuild loads valid transfer state without journal', () async {
    final tempFilePath = '${tempDir.path}/test_file.bin';
    await File(tempFilePath).writeAsBytes(List.filled(1000, 0));

    final snapshot = TransferState(
      totalSize: 1000,
      threadCount: 2,
      chunks: [
        ChunkState(start: 0, end: 499, downloaded: 250),
        ChunkState(start: 500, end: 999, downloaded: 100),
      ],
      url: 'https://example.com/file.bin',
    );

    await StateStore.save(tempFilePath, snapshot, durable: true);

    final loadResult = await StateStore.loadOrCreate(
      tempFilePath,
      url: 'https://example.com/file.bin',
      threadCount: 2,
      knownFileSize: 1000,
    );

    expect(loadResult.created, isFalse);
    expect(loadResult.state.totalSize, equals(1000));
    expect(loadResult.state.chunks.length, equals(2));
    expect(loadResult.state.chunks[0].downloaded, equals(250));
    expect(loadResult.state.chunks[1].downloaded, equals(100));
  });

  test('Unified WAL: journal-only rebuild reconstructs state from journal when snapshot is missing', () async {
    final tempFilePath = '${tempDir.path}/journal_only.bin';
    await File(tempFilePath).writeAsBytes(List.filled(2000, 0));

    final journal = DownloadJournal('$tempFilePath.journal');
    await journal.open();
    await journal.writeInit(2, 2000);
    await journal.writeCheckpoint([400, 350], 2000);
    await journal.flushAndSync();
    await journal.close();

    final loadResult = await StateStore.loadOrCreate(
      tempFilePath,
      url: 'https://example.com/journal_only.bin',
      threadCount: 2,
      knownFileSize: 2000,
    );

    expect(loadResult.created, isFalse);
    expect(loadResult.migratedFrom, equals('journal'));
    expect(loadResult.state.totalSize, equals(2000));
    expect(loadResult.state.chunks.length, equals(2));
    expect(loadResult.state.chunks[0].downloaded, equals(400));
    expect(loadResult.state.chunks[1].downloaded, equals(350));
  });

  test('Unified WAL: both-corrupt produces clean restart (0 progress)', () async {
    final tempFilePath = '${tempDir.path}/both_corrupt.bin';
    final stateFile = File(StateStore.pathFor(tempFilePath));
    final journalFile = File('$tempFilePath.journal');

    await stateFile.writeAsString('{not valid json!!!');
    await journalFile.writeAsString('{not valid json either!!!\n{invalid crc\n');

    final loadResult = await StateStore.loadOrCreate(
      tempFilePath,
      url: 'https://example.com/both_corrupt.bin',
      threadCount: 2,
      knownFileSize: 5000,
    );

    expect(loadResult.created, isTrue);
    expect(loadResult.state.totalSize, equals(5000));
    expect(loadResult.state.downloadedBytes, equals(0));
  });

  test('Unified WAL: journal with newer events than snapshot updates chunk progress', () async {
    final tempFilePath = '${tempDir.path}/newer_journal.bin';
    await File(tempFilePath).writeAsBytes(List.filled(4000, 0));

    final snapshot = TransferState(
      totalSize: 4000,
      threadCount: 2,
      chunks: [
        ChunkState(start: 0, end: 1999, downloaded: 500),
        ChunkState(start: 2000, end: 3999, downloaded: 200),
      ],
      url: 'https://example.com/newer_journal.bin',
    );
    snapshot.updatedAt = DateTime.now().subtract(const Duration(seconds: 10));

    await StateStore.save(tempFilePath, snapshot, durable: true);

    final journal = DownloadJournal('$tempFilePath.journal');
    await journal.open();
    await journal.writeInit(2, 4000);
    await journal.writeCheckpoint([900, 850], 4000);
    await journal.flushAndSync();
    await journal.close();

    final loadResult = await StateStore.loadOrCreate(
      tempFilePath,
      url: 'https://example.com/newer_journal.bin',
      threadCount: 2,
      knownFileSize: 4000,
    );

    expect(loadResult.state.chunks[0].downloaded, equals(900));
    expect(loadResult.state.chunks[1].downloaded, equals(850));
  });

  test('Unified WAL: resetTransferState atomically wipes snapshot, journal, and state (J1)', () async {
    final tempFilePath = '${tempDir.path}/reset_test.bin';
    final stateFile = File(StateStore.pathFor(tempFilePath));
    final journalFile = File('$tempFilePath.journal');
    final payloadFile = File(tempFilePath);

    final state = TransferState(
      totalSize: 1000,
      threadCount: 2,
      chunks: [
        ChunkState(start: 0, end: 499, downloaded: 300),
        ChunkState(start: 500, end: 999, downloaded: 200),
      ],
      url: 'https://example.com/reset_test.bin',
    );
    await StateStore.save(tempFilePath, state, durable: true);

    final journal = DownloadJournal('$tempFilePath.journal');
    await journal.open();
    await journal.writeCheckpoint([300, 200], 1000);
    await journal.flushAndSync();
    await journal.close();

    await payloadFile.writeAsBytes(List.filled(500, 1));

    expect(await stateFile.exists(), isTrue);
    expect(await journalFile.exists(), isTrue);
    expect(await payloadFile.exists(), isTrue);

    await StateStore.resetTransferState(
      tempFilePath,
      state: state,
      deleteTempFile: true,
    );

    expect(await stateFile.exists(), isFalse);
    expect(await journalFile.exists(), isFalse);
    expect(await payloadFile.exists(), isFalse);
    expect(state.chunks[0].downloaded, equals(0));
    expect(state.chunks[1].downloaded, equals(0));
  });
}
