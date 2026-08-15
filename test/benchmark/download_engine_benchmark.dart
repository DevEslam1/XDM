import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/download_journal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadEngine StateStore Benchmark (L3)', () {
    late Directory tempDir;
    late String tempFilePath;
    late TransferState state;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('benchmark_statestore_');
      tempFilePath = '${tempDir.path}/test_download.bin';

      final chunks = List.generate(
        64,
        (i) => ChunkState(
          start: i * 1024 * 1024,
          end: (i + 1) * 1024 * 1024 - 1,
          downloaded: 512 * 1024,
        ),
      );

      state = TransferState(
        url: 'https://example.com/large.iso',
        totalSize: 64 * 1024 * 1024,
        threadCount: 16,
        status: DmxStateStatus.active,
        chunks: chunks,
        updatedAt: DateTime.now(),
      );
    });

    tearDown(() async {
      StateStore.removeCachedPayload(tempFilePath);
      StateStore.stateSaveStrictDedup = false;
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('fingerprint computation is >= 5x faster than jsonEncode + sha256', () {
      // 1. Measure strict SHA-256 + jsonEncode path
      final swStrict = Stopwatch()..start();
      for (int i = 0; i < 1000; i++) {
        final payload = jsonEncode(state.toJson());
        final _ = sha256.convert(utf8.encode(payload)).toString();
      }
      swStrict.stop();
      final strictElapsedUs = swStrict.elapsedMicroseconds;

      // 2. Measure lightweight fingerprint path
      final swFast = Stopwatch()..start();
      for (int i = 0; i < 1000; i++) {
        final _ = StateStore.computeFingerprint(state);
      }
      swFast.stop();
      final fastElapsedUs = swFast.elapsedMicroseconds;

      expect(fastElapsedUs, lessThan(strictElapsedUs));
      final speedup = strictElapsedUs / (fastElapsedUs == 0 ? 1 : fastElapsedUs);
      expect(speedup, greaterThanOrEqualTo(5.0));
    });
  });
}
