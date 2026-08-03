import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal stub implementing [DownloadOrchestratorHost] so we can instantiate
/// [DownloadOrchestrator] and exercise its @visibleForTesting helpers.
class _StubHost implements DownloadOrchestratorHost {
  @override
  void pushProgressTick(String taskId, double progress, double speed) {}

  @override
  bool get enableBackgroundTimers => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late DownloadOrchestrator orchestrator;

  setUp(() {
    orchestrator = DownloadOrchestrator(_StubHost());
  });

  group('isRetryableError', () {
    test('SocketException is retryable', () {
      final error = const SocketException('connection reset');
      expect(orchestrator.isRetryableError(error), isTrue);
    });

    test('TimeoutException is retryable', () {
      final error = TimeoutException('timed out');
      expect(orchestrator.isRetryableError(error), isTrue);
    });

    test('general Exception is retryable', () {
      final error = Exception('something went wrong');
      expect(orchestrator.isRetryableError(error), isTrue);
    });

    test('DownloadIntegrityException is NOT retryable', () {
      final error = const DownloadIntegrityException('checksum mismatch');
      expect(orchestrator.isRetryableError(error), isFalse);
    });

    test('DioException with cancel type is NOT retryable', () {
      final error = DioException(
        type: DioExceptionType.cancel,
        requestOptions: RequestOptions(path: '/'),
      );
      expect(orchestrator.isRetryableError(error), isFalse);
    });

    test('DioException with 403 status is NOT retryable', () {
      final error = DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          statusCode: 403,
          requestOptions: RequestOptions(path: '/'),
        ),
      );
      expect(orchestrator.isRetryableError(error), isFalse);
    });

    test('DioException with 404 status is NOT retryable', () {
      final error = DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          statusCode: 404,
          requestOptions: RequestOptions(path: '/'),
        ),
      );
      expect(orchestrator.isRetryableError(error), isFalse);
    });

    test('DioException with 500 status IS retryable', () {
      final error = DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          statusCode: 500,
          requestOptions: RequestOptions(path: '/'),
        ),
      );
      expect(orchestrator.isRetryableError(error), isTrue);
    });

    test('error containing "ffmpeg" is NOT retryable', () {
      final error = Exception('ffmpeg merge failed');
      expect(orchestrator.isRetryableError(error), isFalse);
    });

    test('error containing "not found" is NOT retryable', () {
      final error = Exception('file not found on disk');
      expect(orchestrator.isRetryableError(error), isFalse);
    });
  });

  group('youtubeMimeCompatible', () {
    test('same MIME types are compatible', () {
      const old = 'https://rr1.googlevideo.com/videoplayback?mime=video%2Fmp4';
      const new_ = 'https://rr2.googlevideo.com/videoplayback?mime=video%2Fmp4';
      expect(orchestrator.youtubeMimeCompatible(old, new_), isTrue);
    });

    test('only video_only streams require muxing', () {
      expect(orchestrator.youtubeStreamRequiresMuxing('video_only'), isTrue);
      expect(orchestrator.youtubeStreamRequiresMuxing('combined'), isFalse);
      expect(orchestrator.youtubeStreamRequiresMuxing('muxed'), isFalse);
      expect(orchestrator.youtubeStreamRequiresMuxing('audio'), isFalse);
    });

    test('different MIME types are NOT compatible', () {
      const old = 'https://rr1.googlevideo.com/videoplayback?mime=video%2Fmp4';
      const new_ =
          'https://rr2.googlevideo.com/videoplayback?mime=audio%2Fwebm';
      expect(orchestrator.youtubeMimeCompatible(old, new_), isFalse);
    });

    test('missing mime param returns true (lenient)', () {
      const old = 'https://rr1.googlevideo.com/videoplayback?mime=video%2Fmp4';
      const new_ = 'https://rr2.googlevideo.com/videoplayback?id=123';
      expect(orchestrator.youtubeMimeCompatible(old, new_), isTrue);
    });

    test('both missing mime returns true', () {
      const old = 'https://example.com/a';
      const new_ = 'https://example.com/b';
      expect(orchestrator.youtubeMimeCompatible(old, new_), isTrue);
    });
  });

  group('html and stream URL guards', () {
    test('rejects YouTube page URLs as resolved stream URLs', () {
      expect(
        orchestrator.shouldRejectResolvedYoutubeUrl(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        ),
        isTrue,
      );
      expect(
        orchestrator.shouldRejectResolvedYoutubeUrl(
          'https://rr1---sn-abc.googlevideo.com/videoplayback?expire=123',
        ),
        isFalse,
      );
    });

    test('detects HTML content-type responses', () {
      final engine = DownloadEngine(dio: Dio());
      expect(engine.isLikelyHtmlResponse('text/html; charset=utf-8'), isTrue);
      expect(engine.isLikelyHtmlResponse('application/xhtml+xml'), isTrue);
      expect(engine.isLikelyHtmlResponse('application/octet-stream'), isFalse);
      expect(engine.isLikelyHtmlResponse(null), isFalse);
    });
  });

  group('errorMessage', () {
    test('DownloadIntegrityException includes message', () {
      final error = const DownloadIntegrityException('size mismatch');
      final msg = orchestrator.errorMessage(error);
      expect(msg, contains('Download integrity check failed'));
      expect(msg, contains('size mismatch'));
    });

    test('IsolateSpawnTimeoutException returns its message', () {
      final error = const IsolateSpawnTimeoutException('spawn timed out');
      expect(orchestrator.errorMessage(error), equals('spawn timed out'));
    });

    test('DioException with 403 produces Forbidden message', () {
      final error = DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          statusCode: 403,
          requestOptions: RequestOptions(path: '/'),
        ),
        message: 'forbidden',
      );
      final msg = orchestrator.errorMessage(error);
      expect(msg, contains('403 Forbidden'));
    });

    test('DioException with 404 produces Not Found message', () {
      final error = DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          statusCode: 404,
          requestOptions: RequestOptions(path: '/'),
        ),
        message: 'gone',
      );
      final msg = orchestrator.errorMessage(error);
      expect(msg, contains('404 Not Found'));
    });

    test('DioException without response produces Dio Error message', () {
      final error = DioException(
        type: DioExceptionType.connectionTimeout,
        requestOptions: RequestOptions(path: '/'),
        message: 'connection timed out',
      );
      final msg = orchestrator.errorMessage(error);
      expect(msg, contains('Dio Error'));
    });

    test('generic Exception produces Error: prefix', () {
      final error = Exception('unexpected');
      final msg = orchestrator.errorMessage(error);
      expect(msg, startsWith('Error:'));
    });
  });

  group('evictStaleCookies', () {
    test('removes entries older than 5 minutes', () {
      final oldTime = DateTime.now().subtract(const Duration(minutes: 10));
      orchestrator.cookieCache['old.example.com'] = (
        cookie: 'old=cookie',
        timestamp: oldTime,
      );
      orchestrator.cookieCache['fresh.example.com'] = (
        cookie: 'fresh=cookie',
        timestamp: DateTime.now(),
      );

      orchestrator.evictStaleCookies();

      expect(orchestrator.cookieCache.containsKey('old.example.com'), isFalse);
      expect(orchestrator.cookieCache.containsKey('fresh.example.com'), isTrue);
    });

    test('keeps all entries when none are stale', () {
      orchestrator.cookieCache['a.com'] = (
        cookie: 'a=1',
        timestamp: DateTime.now(),
      );
      orchestrator.cookieCache['b.com'] = (
        cookie: 'b=2',
        timestamp: DateTime.now(),
      );

      orchestrator.evictStaleCookies();

      expect(orchestrator.cookieCache.length, 2);
    });

    test('evicts oldest when cache exceeds max size', () {
      // Fill cache to max (50) + 1 stale entry
      final oldest = DateTime.now().subtract(const Duration(minutes: 10));
      orchestrator.cookieCache['oldest.com'] = (
        cookie: 'old=1',
        timestamp: oldest,
      );
      for (var i = 0; i < 49; i++) {
        orchestrator.cookieCache['site$i.com'] = (
          cookie: 'c=$i',
          timestamp: DateTime.now(),
        );
      }
      // Now at 50 entries, add one more to trigger eviction
      orchestrator.cookieCache['overflow.com'] = (
        cookie: 'over=flow',
        timestamp: DateTime.now(),
      );

      orchestrator.evictStaleCookies();

      // The oldest entry should have been evicted
      expect(orchestrator.cookieCache.containsKey('oldest.com'), isFalse);
    });
  });
}
