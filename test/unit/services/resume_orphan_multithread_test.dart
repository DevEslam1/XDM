import 'dart:io';

import 'package:dmx/core/services/download_journal.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression: a pre-allocated multi-thread temp file with no `.dmxstate`
/// and no `.journal` must never be mistaken for a fully downloaded file.
///
/// Multi-thread downloads pre-allocate the temp file to `totalSize` and write
/// into non-contiguous ranges. The raw file length therefore says nothing
/// about which bytes are real; crediting it as contiguous progress marks a
/// zero-filled file "complete" and ships file corruption. Single-thread
/// downloads (contiguous from 0) may still be recovered from the raw length.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dmx_orphan_mt_test_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  test(
      'multi-thread orphan file (no state, no journal) is NOT reported complete',
      () async {
    final tempFilePath = '${tempDir.path}/preallocated.dmxpart';
    const totalSize = 1 * 1024 * 1024;

    // Simulate an interrupted multi-thread download: pre-allocated file is
    // exactly totalSize, but only a few scattered ranges were written. There is
    // no snapshot and no journal (crash landed between pre-allocation and the
    // first durable save).
    await File(tempFilePath).writeAsBytes(
      List<int>.filled(totalSize, 0),
      flush: true,
    );

    final result = await StateStore.loadOrCreate(
      tempFilePath,
      url: 'https://example.com/big.bin',
      threadCount: 8,
      knownFileSize: totalSize,
      taskId: 'orphan-mt-task',
    );

    expect(result.state.isComplete, isFalse,
        reason: 'a pre-allocated but unverified multi-thread file must not '
            'be treated as a completed download');
    expect(result.state.downloadedBytes, lessThan(totalSize),
        reason: 'raw file length is non-contiguous progress for multi-thread '
            'downloads and must not be credited');
  });

  test('single-thread orphan file is still recovered from raw length',
      () async {
    final tempFilePath = '${tempDir.path}/single_thread.dmxpart';
    const totalSize = 4096;
    const recovered = 1024;

    await File(tempFilePath).writeAsBytes(
      List<int>.filled(recovered, 7),
      flush: true,
    );

    final result = await StateStore.loadOrCreate(
      tempFilePath,
      url: 'https://example.com/small.bin',
      threadCount: 1,
      knownFileSize: totalSize,
      taskId: 'orphan-st-task',
    );

    expect(result.state.chunks.length, equals(1));
    expect(result.state.chunks.first.downloaded, equals(recovered));
    expect(result.state.isComplete, isFalse);
  });
}
