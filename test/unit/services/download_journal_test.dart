import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/download_journal.dart';

void main() {
  late Directory tempDir;
  late String journalPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('journal_test_');
    journalPath = '${tempDir.path}/test.journal';
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('valid journal records CRC32 and recovers successfully', () async {
    final journal = DownloadJournal(journalPath);
    await journal.open();
    await journal.writeInit(4, 1024 * 1024);
    await journal.recordChunkProgress(0, 100);
    await journal.recordChunkProgress(1, 200);
    await journal.close();

    final recovered = await DownloadJournal.recover(journalPath);
    expect(recovered, isNotNull);
    expect(recovered, equals([100, 200, 0, 0]));
  });

  test('corrupted journal line is skipped gracefully during recovery',
      () async {
    final journal = DownloadJournal(journalPath);
    await journal.open();
    await journal.writeInit(2, 500);
    await journal.recordChunkProgress(0, 50);
    await journal.close();

    // Manually append a corrupted line (invalid CRC)
    final file = File(journalPath);
    await file.writeAsString(
      '{"d":"{\\"t\\":\\"chunk\\",\\"i\\":0,\\"b\\":999}","c":12345}\n',
      mode: FileMode.append,
    );

    // Append a valid line after corrupted line
    await file.writeAsString(
      '${DownloadJournal.crc32([1])}\n', // dummy
      mode: FileMode.append,
    );

    final journal2 = DownloadJournal(journalPath);
    await journal2.open();
    await journal2.recordChunkProgress(1, 100);
    await journal2.close();

    final recovered = await DownloadJournal.recover(journalPath);
    expect(recovered, isNotNull);
    // The corrupted line (b: 999) was skipped, so chunk 0 remains 50 and chunk 1 is 100
    expect(recovered, equals([50, 100]));
  });

  test('legacy unchecksummed journal lines recover cleanly', () async {
    final file = File(journalPath);
    await file.writeAsString(
      '{"t":"init","threads":2,"total":1000}\n'
      '{"t":"chunk","i":0,"b":300}\n'
      '{"t":"chunk","i":1,"b":400}\n',
    );

    final recovered = await DownloadJournal.recover(journalPath);
    expect(recovered, isNotNull);
    expect(recovered, equals([300, 400]));
  });
}
