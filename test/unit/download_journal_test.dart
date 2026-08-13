import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/download_journal.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('journal_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('DownloadJournal', () {
    test('1. writeInit creates journal file', () async {
      final journalPath = '${tempDir.path}/test.journal';
      final journal = DownloadJournal(journalPath);
      await journal.open();
      await journal.writeInit(4, 10000);
      await journal.close();

      final file = File(journalPath);
      expect(await file.exists(), isTrue);
      final content = await file.readAsString();
      expect(content, contains('"t":"init"'));
    });

    test('2. recordChunkProgress appends entries over threshold', () async {
      final journalPath = '${tempDir.path}/test_chunk.journal';
      final journal = DownloadJournal(journalPath);
      await journal.open();
      await journal.writeInit(4, 10000);
      // Send >64KB bytes to trigger record
      await journal.recordChunkProgress(0, 70000);
      await journal.close();

      final content = await File(journalPath).readAsString();
      expect(content, contains('"t":"chunk"'));
    });

    test('3. writeCheckpoint writes checkpoint', () async {
      final journalPath = '${tempDir.path}/test_ckpt.journal';
      final journal = DownloadJournal(journalPath);
      await journal.open();
      await journal.writeInit(4, 10000);
      await journal.writeCheckpoint([2500, 2500, 2500, 2500], 10000);
      await journal.close();

      final content = await File(journalPath).readAsString();
      expect(content, contains('"t":"checkpoint"'));
    });

    test('4. recover() reads last checkpoint correctly', () async {
      final journalPath = '${tempDir.path}/test_recover.journal';
      final journal = DownloadJournal(journalPath);
      await journal.open();
      await journal.writeInit(4, 10000);
      await journal.writeCheckpoint([1000, 2000, 3000, 4000], 10000);
      await journal.close();

      final recovered = await DownloadJournal.recover(journalPath);
      expect(recovered, isNotNull);
      expect(recovered, equals([1000, 2000, 3000, 4000]));
    });

    test('5. recover() skips corrupt lines (bad CRC)', () async {
      final journalPath = '${tempDir.path}/test_corrupt.journal';
      final file = File(journalPath);
      await file.writeAsString(
        '{"t":"checkpoint","v":2,"chunks":[500,500],"total":1000,"c":999999999}\n',
      );

      final recovered = await DownloadJournal.recover(journalPath);
      expect(recovered, isNull);
    });

    test('6. recover() returns null for empty or non-existent file', () async {
      final nonExistent =
          await DownloadJournal.recover('${tempDir.path}/non_existent.journal');
      expect(nonExistent, isNull);

      final emptyFile = File('${tempDir.path}/empty.journal');
      await emptyFile.create();
      final emptyRes = await DownloadJournal.recover(emptyFile.path);
      expect(emptyRes, isNull);
    });

    test('7. Compaction triggers at threshold', () async {
      final journalPath = '${tempDir.path}/test_compact.journal';
      final journal =
          DownloadJournal(journalPath, compactionThresholdBytes: 100);
      await journal.open();
      await journal.writeInit(2, 2000);
      await journal.writeCheckpoint([1000, 1000], 2000);
      await journal.close();

      expect(await File(journalPath).exists(), isTrue);
    });

    test('8. close() flushes and closes', () async {
      final journalPath = '${tempDir.path}/test_close.journal';
      final journal = DownloadJournal(journalPath);
      await journal.open();
      await journal.writeInit(2, 5000);
      await journal.close();

      final content = await File(journalPath).readAsString();
      expect(content.isNotEmpty, isTrue);
    });
  });
}
