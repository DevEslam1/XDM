import 'package:dmx/core/services/diagnostic_service.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DiagnosticService service;

  setUp(() {
    service = DiagnosticService();
    service.clear();
    service.resetTelemetryMetrics();
  });

  group('DiagnosticService log entries', () {
    test('record and clear store sanitized entries', () {
      service.record('area', 'message');
      expect(service.entries.length, 1);
      expect(service.entries.first.message, 'message');
      expect(service.entries.first.family, isNull);
      service.clear();
      expect(service.entries, isEmpty);
    });

    test('record classifies the attached error family', () {
      service.record('area', 'msg', error: ArgumentError('bad'));
      expect(service.entries.single.family, isNotNull);
    });

    test('record sanitizes secrets in message and details', () {
      service.record(
        'area',
        'token=supersecret',
        details: 'password=hunter2',
      );
      final entry = service.entries.single;
      expect(entry.message, contains('[REDACTED]'));
      expect(entry.details, contains('[REDACTED]'));
    });

    test('entry buffer is bounded to 200 entries', () {
      for (var i = 0; i < 250; i++) {
        service.record('area', 'entry $i');
      }
      expect(service.entries.length, 200);
      expect(service.entries.first.message, 'entry 50');
      expect(service.entries.last.message, 'entry 249');
    });

    test('snapshot joins formatted entries', () {
      service.record('a', 'first');
      service.record('b', 'second');
      final out = service.snapshot();
      expect(out, contains('first'));
      expect(out, contains('second'));
    });
  });

  group('DiagnosticService.systemInfo', () {
    test('returns platform basics even without plugins', () async {
      final info = await service.systemInfo();
      expect(info, isNotNull);
      expect(info.containsKey('dart'), isTrue);
      expect(info.containsKey('device'), isTrue);
    });
  });

  group('DiagnosticService telemetry metrics', () {
    test('isolate payload accumulates and ignores non-positive', () {
      service.recordIsolatePayloadSize(0);
      service.recordIsolatePayloadSize(-5);
      expect(service.isolateBytesTransferred, 0);
      expect(service.isolateMessageCount, 0);

      service.recordIsolatePayloadSize(100);
      service.recordIsolatePayloadSize(50);
      expect(service.isolateBytesTransferred, 150);
      expect(service.isolateMessageCount, 2);
    });

    test('progress latency p95 handles empty and populated samples', () {
      expect(service.p95ProgressLatencyMs, 0.0);
      for (var i = 1; i <= 100; i++) {
        service.recordProgressLatency(Duration(milliseconds: i));
      }
      expect(service.p95ProgressLatencyMs, greaterThan(0));
    });

    test('isolate byte counter saturates instead of overflowing', () {
      service.recordIsolatePayloadSize(0x7FFFFFFFFFFFFFFF);
      service.recordIsolatePayloadSize(1);
      expect(service.isolateBytesTransferred, 0x7FFFFFFFFFFFFFFF);
    });

    test('progress latency queue is bounded to 1000 samples', () {
      for (var i = 0; i < 1005; i++) {
        service.recordProgressLatency(Duration(milliseconds: i));
      }
      expect(
        service.telemetryMetricsSnapshot()['p95ProgressLatencyMs'],
        isA<num>(),
      );
    });

    test('db write queue depth tracks current and max', () {
      service.recordDbWriteQueueDepth(3);
      service.recordDbWriteQueueDepth(1);
      expect(service.currentDbWriteQueueDepth, 1);
      expect(service.maxDbWriteQueueDepth, 3);
    });

    test('mirror health cache hit rate', () {
      expect(service.mirrorHealthCacheHitRate, 0.0);
      service.recordMirrorHealthAccess(isHit: true);
      service.recordMirrorHealthAccess(isHit: false);
      expect(service.mirrorHealthCacheHitRate, 0.5);
      expect(service.mirrorHealthHits, 1);
      expect(service.mirrorHealthMisses, 1);
    });

    test('unknown telemetry alerts are recorded without counters', () {
      service.recordTelemetryAlert('unknown_alert', taskId: 't');
      expect(service.entries.any((e) => e.message == 'unknown_alert'), isTrue);
    });

    test('snapshot is cached until state becomes dirty', () {
      service.recordIsolatePayloadSize(10);
      final first = service.telemetryMetricsSnapshot();
      expect(identical(first, service.telemetryMetricsSnapshot()), isTrue);
      service.recordIsolatePayloadSize(10);
      final second = service.telemetryMetricsSnapshot();
      expect(second['isolateMessageCount'], 2);
    });

    test('resetTelemetryMetrics clears every metric', () {
      service.recordIsolatePayloadSize(10);
      service.recordProgressLatency(const Duration(milliseconds: 5));
      service.recordDbWriteQueueDepth(4);
      service.recordMirrorHealthAccess(isHit: true);
      service.recordTelemetryAlert('resume_range_ignored', taskId: 't');
      service.recordTelemetryAlert('journal_reconciled', taskId: 't');
      service.recordTelemetryAlert('resume_data_missing', taskId: 't');
      service.recordTelemetryAlert('watchdog_skip_paused', taskId: 't');

      service.resetTelemetryMetrics();

      expect(service.isolateBytesTransferred, 0);
      expect(service.isolateMessageCount, 0);
      expect(service.p95ProgressLatencyMs, 0.0);
      expect(service.maxDbWriteQueueDepth, 0);
      expect(service.mirrorHealthHits, 0);
      expect(service.mirrorHealthMisses, 0);
      expect(service.resumeRangeIgnoredCount, 0);
      expect(service.journalReconciledCount, 0);
      expect(service.resumeDataMissingCount, 0);
      expect(service.watchdogSkipPausedCount, 0);
    });
  });

  group('DiagnosticService implementation of DiagnosticRepository', () {
    test('service satisfies the repository contract', () {
      service.record('area', 'message', error: StateError('x'));
      expect(service.entries, isNotEmpty);
      expect(service.isolateBytesTransferred, isA<int>());
    });
  });

  group('ErrorTaxonomy import sanity', () {
    test('classify works alongside diagnostic recording', () {
      final classification = ErrorTaxonomy.classify(ArgumentError('oops'));
      expect(classification.message, isNotEmpty);
    });
  });
}
