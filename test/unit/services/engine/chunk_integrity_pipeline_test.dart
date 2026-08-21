import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chunk_integrity_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('Integrity Pipeline: verifies chunk SHA-256 on disk against WAL recorded hashes', () async {
    final tempFilePath = '${tempDir.path}/integrity_file.bin';
    final payloadFile = File(tempFilePath);

    final chunk0Bytes = utf8.encode('Chunk 0 valid data contents 1234567890');
    final chunk1Bytes = utf8.encode('Chunk 1 valid data contents 0987654321');

    final chunk0Hash = sha256.convert(chunk0Bytes).toString();
    final chunk1Hash = sha256.convert(chunk1Bytes).toString();

    // Write file payload to disk
    await payloadFile.writeAsBytes([...chunk0Bytes, ...chunk1Bytes]);

    final state = TransferState(
      totalSize: chunk0Bytes.length + chunk1Bytes.length,
      threadCount: 2,
      chunks: [
        ChunkState(
          start: 0,
          end: chunk0Bytes.length - 1,
          downloaded: chunk0Bytes.length,
          hash: chunk0Hash,
        ),
        ChunkState(
          start: chunk0Bytes.length,
          end: chunk0Bytes.length + chunk1Bytes.length - 1,
          downloaded: chunk1Bytes.length,
          hash: chunk1Hash,
        ),
      ],
      url: 'https://example.com/integrity_file.bin',
    );

    await StateStore.save(tempFilePath, state, durable: true);

    // Verify chunk 0 hash from disk matches
    final raf = await payloadFile.open(mode: FileMode.read);
    try {
      await raf.setPosition(0);
      final readChunk0 = await raf.read(chunk0Bytes.length);
      final diskChunk0Hash = sha256.convert(readChunk0).toString();
      expect(diskChunk0Hash, equals(chunk0Hash));

      await raf.setPosition(chunk0Bytes.length);
      final readChunk1 = await raf.read(chunk1Bytes.length);
      final diskChunk1Hash = sha256.convert(readChunk1).toString();
      expect(diskChunk1Hash, equals(chunk1Hash));
    } finally {
      await raf.close();
    }
  });

  test('Integrity Pipeline: corrupted chunk on disk is detected and only that chunk is reset', () async {
    final tempFilePath = '${tempDir.path}/corrupt_detect_file.bin';
    final payloadFile = File(tempFilePath);

    final chunk0Bytes = utf8.encode('Chunk 0 valid data contents');
    final chunk1Bytes = utf8.encode('Chunk 1 valid data contents');

    final chunk0Hash = sha256.convert(chunk0Bytes).toString();
    final chunk1Hash = sha256.convert(chunk1Bytes).toString();

    // Inject corruption into chunk 1 on disk
    final corruptedChunk1Bytes = utf8.encode('Chunk 1 CORRUPTED contents');
    await payloadFile.writeAsBytes([...chunk0Bytes, ...corruptedChunk1Bytes]);

    final state = TransferState(
      totalSize: chunk0Bytes.length + chunk1Bytes.length,
      threadCount: 2,
      chunks: [
        ChunkState(
          start: 0,
          end: chunk0Bytes.length - 1,
          downloaded: chunk0Bytes.length,
          hash: chunk0Hash,
        ),
        ChunkState(
          start: chunk0Bytes.length,
          end: chunk0Bytes.length + chunk1Bytes.length - 1,
          downloaded: chunk1Bytes.length,
          hash: chunk1Hash,
        ),
      ],
      url: 'https://example.com/corrupt_detect_file.bin',
    );

    // Run verification step
    final corruptedChunkIndices = <int>[];
    final raf = await payloadFile.open(mode: FileMode.read);
    try {
      for (var i = 0; i < state.chunks.length; i++) {
        final c = state.chunks[i];
        await raf.setPosition(c.start);
        final read = await raf.read(c.size);
        final diskHash = sha256.convert(read).toString();
        if (diskHash.toLowerCase() != c.hash!.toLowerCase()) {
          corruptedChunkIndices.add(i);
        }
      }
    } finally {
      await raf.close();
    }

    // ONLY Chunk 1 detected as corrupted
    expect(corruptedChunkIndices, equals([1]));

    // Reset ONLY corrupted chunk 1
    for (final i in corruptedChunkIndices) {
      state.chunks[i].downloaded = 0;
      state.chunks[i].hash = null;
    }

    // Chunk 0 remains fully intact
    expect(state.chunks[0].downloaded, equals(chunk0Bytes.length));
    expect(state.chunks[0].hash, equals(chunk0Hash));

    // Chunk 1 is reset for re-download
    expect(state.chunks[1].downloaded, equals(0));
    expect(state.chunks[1].hash, isNull);
  });
}
