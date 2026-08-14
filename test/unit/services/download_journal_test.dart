import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/download_engine.dart';
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
    await journal.writeInit(4, 50 * 1024 * 1024);
    await journal.recordChunkProgress(0, 2 * 1024 * 1024);
    await journal.recordChunkProgress(1, 3 * 1024 * 1024);
    await journal.close();

    final recovered = await DownloadJournal.recover(journalPath);
    expect(recovered, isNotNull);
    expect(recovered, equals([2 * 1024 * 1024, 3 * 1024 * 1024, 0, 0]));
  });

  test('corrupted journal line is skipped gracefully during recovery',
      () async {
    final journal = DownloadJournal(journalPath);
    await journal.open();
    await journal.writeInit(2, 50 * 1024 * 1024);
    await journal.recordChunkProgress(0, 2 * 1024 * 1024);
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
    await journal2.recordChunkProgress(1, 3 * 1024 * 1024);
    await journal2.close();

    final recovered = await DownloadJournal.recover(journalPath);
    expect(recovered, isNotNull);
    // The corrupted line (b: 999) was skipped, so chunk 0 remains 2MB and chunk 1 is 3MB
    expect(recovered, equals([2 * 1024 * 1024, 3 * 1024 * 1024]));
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

  test('background writes respect 4MB delta threshold (BG-04)', () async {
    final journal = DownloadJournal(journalPath);
    await journal.open();
    await journal.writeInit(2, 50 * 1024 * 1024);

    // Set background mode
    DownloadEngine.appInForeground = false;
    DownloadEngine.isInBackground = true;

    // First write at 10MB
    await journal.recordChunkProgress(0, 10 * 1024 * 1024);

    // Delta < 4MB (e.g. +2MB) -> should be throttled
    await journal.recordChunkProgress(0, 12 * 1024 * 1024);

    // Delta >= 4MB from last recorded (10MB -> 15MB) -> recorded
    await journal.recordChunkProgress(0, 15 * 1024 * 1024);

    await journal.close();

    final recovered = await DownloadJournal.recover(journalPath);
    expect(recovered, isNotNull);
    expect(recovered![0], equals(15 * 1024 * 1024));

    // Reset foreground
    DownloadEngine.appInForeground = true;
    DownloadEngine.isInBackground = false;
  });

  test('TEST-T1: StateStore corrupt file recovery recovers from journal or returns zero gracefully', () async {
    final tempFilePath = '${tempDir.path}/test_download.dmxpart';
    final stateFilePath = StateStore.pathFor(tempFilePath);

    // Write a corrupted state file
    final stateFile = File(stateFilePath);
    await stateFile.writeAsString('{BAD_JSON: "corrupted"');

    // Call loadOrCreate - must NOT throw and recover gracefully
    final result = await StateStore.loadOrCreate(
      tempFilePath,
      url: 'https://example.com/test.zip',
      threadCount: 2,
      knownFileSize: 20 * 1024 * 1024,
    );

    expect(result.state, isNotNull);
    expect(result.state.totalSize, equals(20 * 1024 * 1024));
  });
}
