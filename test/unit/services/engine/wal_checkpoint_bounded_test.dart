import 'dart:io';
import 'package:dmx/core/services/download_journal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('wal_checkpoint_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
      'Unified WAL Checkpoint: simulated 1GB transfer journal file stays bounded (< 64KB)',
      () async {
    final tempFilePath = '${tempDir.path}/large_1gb_file.bin';
    final journalPath = '$tempFilePath.journal';
    const totalSize = 1024 * 1024 * 1024; // 1 GB
    const threadCount = 4;

    final journal = DownloadJournal(journalPath);
    await journal.open();
    await journal.writeInit(threadCount, totalSize);

    final chunkProgress = [0, 0, 0, 0];
    const chunkSize = totalSize ~/ threadCount;

    // Simulate 200 chunk progress steps across 4 threads (totaling 1GB)
    for (var step = 1; step <= 200; step++) {
      for (var thread = 0; thread < threadCount; thread++) {
        chunkProgress[thread] = ((step / 200) * chunkSize).toInt();
        await journal.recordChunkProgress(
          thread,
          chunkProgress[thread],
          hash: 'hash_step_${step}_thread_$thread',
        );
      }

      // Checkpoint every 20 steps (simulating periodic state saves / chunk boundaries)
      if (step % 20 == 0) {
        await journal.writeCheckpoint(
          chunkProgress,
          totalSize,
          truncateDeltas: true,
        );
      }
    }

    await journal.flushAndSync();
    await journal.close();

    final journalFile = File(journalPath);
    expect(await journalFile.exists(), isTrue);
    final journalLength = await journalFile.length();

    // Verify journal file is strictly bounded (< 64KB)
    expect(journalLength, lessThan(64 * 1024));

    // Verify recovery after compaction reconstructs exact final state
    final recovered = await DownloadJournal.recoverWithDetails(journalPath);
    expect(recovered, isNotNull);
    expect(recovered!.totalSize, equals(totalSize));
    expect(recovered.threadCount, equals(threadCount));
    expect(recovered.chunkBytes.length, equals(threadCount));
    for (var thread = 0; thread < threadCount; thread++) {
      expect(recovered.chunkBytes[thread], equals(chunkSize));
    }
  });
}
