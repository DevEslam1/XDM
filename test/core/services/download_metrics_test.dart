import 'package:dmx/core/services/download_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadMetrics', () {
    test('markCompleted sets completedAt and elapsed is positive', () async {
      final m = DownloadMetrics(taskId: 't1', url: 'https://e.com/a?token=x');
      expect(m.completedAt, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      m.markCompleted();
      expect(m.completedAt, isNotNull);
      expect(m.elapsed.inMilliseconds, greaterThanOrEqualTo(0));
    });

    test('avgSpeedBps is computed when bytes were downloaded', () {
      final m = DownloadMetrics(taskId: 't1', url: 'https://e.com/a')
        ..totalBytesDownloaded = 1000
        ..markCompleted();
      expect(m.avgSpeedBps, greaterThanOrEqualTo(0));
    });

    test('threadEfficiency defaults to 1.0 for single thread', () {
      final m = DownloadMetrics(taskId: 't1', url: 'u')..effectiveThreads = 1;
      expect(m.threadEfficiency, 1.0);
    });

    test('threadEfficiency defaults to 1.0 when peak speed is zero', () {
      final m = DownloadMetrics(taskId: 't1', url: 'u')
        ..effectiveThreads = 4
        ..peakSpeedBps = 0;
      expect(m.threadEfficiency, 1.0);
    });

    test('threadEfficiency is clamped to 1.0', () {
      final m = DownloadMetrics(taskId: 't1', url: 'u')
        ..effectiveThreads = 4
        ..peakSpeedBps = 1
        ..totalBytesDownloaded = 1000000
        ..markCompleted();
      expect(m.threadEfficiency, lessThanOrEqualTo(1.0));
    });

    test('toJson redacts sensitive query params and round-trips', () {
      final m = DownloadMetrics(
        taskId: 't1',
        url: 'https://e.com/a?token=secret&x=1',
      )
        ..timeToFirstByteMs = 12
        ..usedHttp2 = true
        ..requestedThreads = 8
        ..effectiveThreads = 4
        ..totalBytesDownloaded = 2048
        ..peakSpeedBps = 100
        ..totalRetries = 2
        ..resumed = true
        ..resumeBytesSaved = 512
        ..checksumAlgorithm = 'sha256'
        ..checksumVerified = true
        ..checksumPassed = true
        ..errorCount = 1
        ..lastError = 'oops'
        ..mirrorSwitches = 3
        ..markCompleted();

      final json = m.toJson();
      expect(json['taskId'], 't1');
      expect(json['url'], isNot(contains('secret')));
      expect(json['mirrorSwitches'], 3);

      final restored = DownloadMetrics.fromJson(json);
      expect(restored.taskId, 't1');
      expect(restored.usedHttp2, isTrue);
      expect(restored.checksumPassed, isTrue);
      expect(restored.mirrorSwitches, 3);
      expect(restored.completedAt, isNotNull);
    });

    test('fromJson tolerates minimal payloads', () {
      final restored = DownloadMetrics.fromJson({});
      expect(restored.taskId, '');
      expect(restored.url, '');
      expect(restored.completedAt, isNull);
    });

    test('toSummary includes checksum and error sections', () {
      final m = DownloadMetrics(taskId: 't1', url: 'https://e.com/a')
        ..usedHttp2 = true
        ..requestedThreads = 8
        ..effectiveThreads = 4
        ..resumed = true
        ..resumeBytesSaved = 1024
        ..totalRetries = 1
        ..checksumVerified = true
        ..checksumAlgorithm = 'sha256'
        ..checksumPassed = true
        ..errorCount = 2
        ..lastError = 'boom';
      final summary = m.toSummary();
      expect(summary, contains('sha256'));
      expect(summary, contains('PASS'));
      expect(summary, contains('Errors: 2'));
    });

    test('toSummary omits sections when flags are false', () {
      final m = DownloadMetrics(taskId: 't1', url: 'u');
      final summary = m.toSummary();
      expect(summary, isNot(contains('Checksum')));
      expect(summary, isNot(contains('Errors:')));
    });
  });
}
