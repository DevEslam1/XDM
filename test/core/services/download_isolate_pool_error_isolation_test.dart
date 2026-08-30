import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_journal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChunkResult & Error Isolation', () {
    test('ChunkResult captures success state and attempts count', () {
      final chunk = ChunkState(start: 0, end: 100);
      final result = ChunkResult(
        chunk: chunk,
        success: true,
        attempts: 1,
      );

      expect(result.success, isTrue);
      expect(result.attempts, equals(1));
      expect(result.error, isNull);
    });

    test('ChunkResult captures failure state and error details', () {
      final chunk = ChunkState(start: 0, end: 100);
      final error = Exception('Network error');
      final result = ChunkResult(
        chunk: chunk,
        success: false,
        error: error,
        attempts: 3,
      );

      expect(result.success, isFalse);
      expect(result.attempts, equals(3));
      expect(result.error, equals(error));
    });

    test('Error isolation allows other chunks to complete when one fails',
        () async {
      final chunks = [
        ChunkState(start: 0, end: 100),
        ChunkState(start: 101, end: 200),
        ChunkState(start: 201, end: 300),
      ];

      final results = await Future.wait<ChunkResult>(
        chunks.map((chunk) async {
          if (chunk.start == 101) {
            return ChunkResult(
              chunk: chunk,
              success: false,
              error: Exception('Chunk 1 failed'),
              attempts: 3,
            );
          }
          chunk.downloaded = 100;
          return ChunkResult(chunk: chunk, success: true, attempts: 1);
        }),
        eagerError: false,
      );

      expect(results.length, equals(3));
      expect(results[0].success, isTrue);
      expect(results[1].success, isFalse);
      expect(results[2].success, isTrue);
    });

    test('Retry logic retries failed chunk up to maxAttempts', () async {
      var attempts = 0;
      Future<ChunkResult> runChunkWithRetry(ChunkState chunk) async {
        const maxAttempts = 3;
        Object? lastError;
        while (attempts < maxAttempts) {
          attempts++;
          if (attempts < 2) {
            lastError = Exception('Temporary failure');
            continue;
          }
          return ChunkResult(chunk: chunk, success: true, attempts: attempts);
        }
        return ChunkResult(
            chunk: chunk, success: false, error: lastError, attempts: attempts);
      }

      final chunk = ChunkState(start: 0, end: 100);
      final result = await runChunkWithRetry(chunk);

      expect(result.success, isTrue);
      expect(result.attempts, equals(2));
    });

    test('All retries exhausted returns failed ChunkResult', () async {
      var attempts = 0;
      Future<ChunkResult> runChunkWithRetry(ChunkState chunk) async {
        const maxAttempts = 3;
        Object? lastError;
        while (attempts < maxAttempts) {
          attempts++;
          lastError = Exception('Persistent error attempt $attempts');
        }
        return ChunkResult(
            chunk: chunk, success: false, error: lastError, attempts: attempts);
      }

      final chunk = ChunkState(start: 0, end: 100);
      final result = await runChunkWithRetry(chunk);

      expect(result.success, isFalse);
      expect(result.attempts, equals(3));
      expect(result.error.toString(), contains('attempt 3'));
    });

    test('Concurrent failure of multiple chunks handles eagerError false',
        () async {
      final chunks = [
        ChunkState(start: 0, end: 100),
        ChunkState(start: 101, end: 200),
        ChunkState(start: 201, end: 300),
      ];

      final results = await Future.wait<ChunkResult>(
        chunks.map((chunk) async {
          return ChunkResult(
            chunk: chunk,
            success: false,
            error: Exception('Error at ${chunk.start}'),
            attempts: 3,
          );
        }),
        eagerError: false,
      );

      expect(results.every((r) => !r.success), isTrue);
      expect(results.length, equals(3));
    });
  });
}
