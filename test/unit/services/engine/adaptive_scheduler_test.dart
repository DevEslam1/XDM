import 'package:dmx/core/services/engines/http_download_engine.dart';
import 'package:dmx/core/services/engines/speed_predictor.dart';
import 'package:dmx/core/services/protocol_fallback_memory.dart';
import 'package:dmx/core/services/transfer_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ProtocolFallbackMemory.clearConcurrencyCaps();
  });

  group('Adaptive Chunk Scheduler Unit Tests', () {
    test('ChunkScheduler: canSplitChunk requires >= 2MB remaining', () {
      // Chunk with 1MB remaining cannot be split
      final smallChunk = ChunkState(
        start: 0,
        end: 1024 * 1024 - 1, // 1MB total
        downloaded: 0,
      );
      expect(ChunkScheduler.canSplitChunk(smallChunk), isFalse);
      expect(ChunkScheduler.trySplitChunk(smallChunk), isNull);

      // Chunk with 4MB remaining can be split into two 2MB chunks
      final largeChunk = ChunkState(
        start: 0,
        end: 4 * 1024 * 1024 - 1, // 4MB total
        downloaded: 0,
      );
      expect(ChunkScheduler.canSplitChunk(largeChunk), isTrue);

      final split = ChunkScheduler.trySplitChunk(largeChunk);
      expect(split, isNotNull);
      final (first, second) = split!;

      expect(first.start, equals(0));
      expect(first.end, equals(2 * 1024 * 1024 - 1));
      expect(second.start, equals(2 * 1024 * 1024));
      expect(second.end, equals(4 * 1024 * 1024 - 1));
      expect(second.downloaded, equals(0));
    });

    test('ChunkScheduler: trySplitChunk respects downloaded bytes offset', () {
      // 6MB chunk with 3MB already downloaded -> 3MB remaining (can split)
      final chunk = ChunkState(
        start: 0,
        end: 6 * 1024 * 1024 - 1,
        downloaded: 3 * 1024 * 1024,
      );
      expect(ChunkScheduler.canSplitChunk(chunk), isTrue);

      final split = ChunkScheduler.trySplitChunk(chunk);
      expect(split, isNotNull);
      final (first, second) = split!;

      expect(first.start, equals(0));
      expect(first.end,
          equals(chunk.start + 3 * 1024 * 1024 + (3 * 1024 * 1024 ~/ 2) - 1));
      expect(second.start, equals(first.end + 1));
      expect(second.end, equals(chunk.end));
      expect(second.downloaded, equals(0));
    });

    test('SpeedPredictor: computes EMA speed trends and goodput correctly', () {
      final predictor = SpeedPredictor();

      predictor.addSample(1000.0);
      expect(predictor.predictedSpeed, equals(1000.0));

      predictor.addSample(2000.0);
      // EMA: 0.3 * 2000 + 0.7 * 1000 = 600 + 700 = 1300
      expect(predictor.predictedSpeed, closeTo(1300.0, 0.01));
    });

    test(
        'ProtocolFallbackMemory: learns and retrieves per-host concurrency caps',
        () {
      const host = 'download.example.com';
      expect(ProtocolFallbackMemory.getHostConcurrencyCap(host), isNull);

      ProtocolFallbackMemory.recordHostConcurrencyCap(host, 3);
      expect(ProtocolFallbackMemory.getHostConcurrencyCap(host), equals(3));

      ProtocolFallbackMemory.recordHostConcurrencyCap(
          'https://download.example.com/file.zip', 2);
      expect(ProtocolFallbackMemory.getHostConcurrencyCap(host), equals(2));

      ProtocolFallbackMemory.clearConcurrencyCaps();
      expect(ProtocolFallbackMemory.getHostConcurrencyCap(host), isNull);
    });
  });
}
