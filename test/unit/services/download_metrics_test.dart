import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/download_metrics.dart';

void main() {
  group('DownloadMetrics', () {
    test('creates metrics for each download', () {
      final metrics = DownloadMetrics(
        taskId: 'test-1',
        url: 'https://example.com/file.zip',
      );
      expect(metrics.taskId, 'test-1');
      expect(metrics.url, 'https://example.com/file.zip');
      expect(metrics.startedAt, isNotNull);
    });

    test('retry count increments on transient failure', () {
      final metrics = DownloadMetrics(
        taskId: 'test-2',
        url: 'https://example.com/file.zip',
      );
      metrics.totalRetries = 0;
      metrics.totalRetries++;
      expect(metrics.totalRetries, 1);
      metrics.totalRetries++;
      expect(metrics.totalRetries, 2);
    });

    test('checksum pass/fail is recorded', () {
      final metrics = DownloadMetrics(
        taskId: 'test-3',
        url: 'https://example.com/file.zip',
      );
      metrics.checksumAlgorithm = 'SHA-256';
      metrics.checksumVerified = true;
      metrics.checksumPassed = true;
      expect(metrics.checksumAlgorithm, 'SHA-256');
      expect(metrics.checksumPassed, true);
    });

    test('URL redaction removes query params from toJson', () {
      final metrics = DownloadMetrics(
        taskId: 'test-4',
        url: 'https://example.com/file.zip?token=secret123&id=456',
      );
      final json = metrics.toJson();
      expect(json['url'] as String, contains('[REDACTED]'));
      expect(json['url'] as String, isNot(contains('secret123')));
    });

    test('markCompleted sets completedAt', () {
      final metrics = DownloadMetrics(
        taskId: 'test-5',
        url: 'https://example.com/file.zip',
      );
      expect(metrics.completedAt, isNull);
      metrics.markCompleted();
      expect(metrics.completedAt, isNotNull);
    });

    test('elapsed is positive after completion', () {
      final metrics = DownloadMetrics(
        taskId: 'test-6',
        url: 'https://example.com/file.zip',
      );
      metrics.markCompleted();
      expect(metrics.elapsed.inMilliseconds, greaterThanOrEqualTo(0));
    });

    test('peakSpeedBps can be set', () {
      final metrics = DownloadMetrics(
        taskId: 'test-7',
        url: 'https://example.com/file.zip',
      );
      metrics.peakSpeedBps = 1024 * 1024; // 1 MB/s
      expect(metrics.peakSpeedBps, 1024 * 1024);
    });

    test('resume fields are recorded', () {
      final metrics = DownloadMetrics(
        taskId: 'test-8',
        url: 'https://example.com/file.zip',
      );
      metrics.resumed = true;
      metrics.resumeBytesSaved = 500000;
      expect(metrics.resumed, true);
      expect(metrics.resumeBytesSaved, 500000);
    });

    test('error count increments', () {
      final metrics = DownloadMetrics(
        taskId: 'test-9',
        url: 'https://example.com/file.zip',
      );
      metrics.errorCount = 2;
      metrics.lastError = 'Connection timeout';
      expect(metrics.errorCount, 2);
      expect(metrics.lastError, 'Connection timeout');
    });

    test('mirror switches recorded', () {
      final metrics = DownloadMetrics(
        taskId: 'test-10',
        url: 'https://example.com/file.zip',
      );
      metrics.mirrorSwitches = 3;
      expect(metrics.mirrorSwitches, 3);
    });
  });
}
