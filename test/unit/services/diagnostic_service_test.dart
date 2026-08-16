import 'package:dmx/core/services/diagnostic_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DiagnosticService Telemetry Metrics Tests (FIX-23)', () {
    late DiagnosticService service;

    setUp(() {
      service = DiagnosticService();
    });

    test('isolate payload metrics track bytes and count accurately', () {
      service.recordIsolatePayloadSize(1024);
      service.recordIsolatePayloadSize(2048);
      service.recordIsolatePayloadSize(4096);

      expect(service.isolateBytesTransferred, equals(7168));
      expect(service.isolateMessageCount, equals(3));
    });

    test('P95 progress notification latency calculates 95th percentile', () {
      // Add 100 samples from 1ms to 100ms
      for (int i = 1; i <= 100; i++) {
        service.recordProgressLatency(Duration(milliseconds: i));
      }

      final p95 = service.p95ProgressLatencyMs;
      expect(p95, greaterThanOrEqualTo(95.0));
      expect(p95, lessThanOrEqualTo(96.0));
    });

    test('database write queue depth tracks current and peak depth', () {
      service.recordDbWriteQueueDepth(5);
      expect(service.currentDbWriteQueueDepth, equals(5));
      expect(service.maxDbWriteQueueDepth, equals(5));

      service.recordDbWriteQueueDepth(12);
      expect(service.currentDbWriteQueueDepth, equals(12));
      expect(service.maxDbWriteQueueDepth, equals(12));

      service.recordDbWriteQueueDepth(3);
      expect(service.currentDbWriteQueueDepth, equals(3));
      expect(service.maxDbWriteQueueDepth, equals(12)); // Peak preserved
    });

    test('mirror health hit rate tracks hits, misses, and hit percentage', () {
      expect(service.mirrorHealthCacheHitRate, equals(0.0));

      service.recordMirrorHealthAccess(isHit: true);
      service.recordMirrorHealthAccess(isHit: true);
      service.recordMirrorHealthAccess(isHit: true);
      service.recordMirrorHealthAccess(isHit: false);

      expect(service.mirrorHealthHits, equals(3));
      expect(service.mirrorHealthMisses, equals(1));
      expect(service.mirrorHealthCacheHitRate, equals(0.75));
    });

    test('telemetryMetricsSnapshot exports complete map', () {
      service.recordIsolatePayloadSize(500);
      service.recordProgressLatency(const Duration(milliseconds: 10));
      service.recordDbWriteQueueDepth(4);
      service.recordMirrorHealthAccess(isHit: true);

      final snap = service.telemetryMetricsSnapshot();
      expect(snap['isolateMessageBytes'], equals(500));
      expect(snap['isolateMessageCount'], equals(1));
      expect(snap['p95ProgressLatencyMs'], equals(10.0));
      expect(snap['currentDbWriteQueueDepth'], equals(4));
      expect(snap['maxDbWriteQueueDepth'], equals(4));
      expect(snap['mirrorHealthHits'], equals(1));
      expect(snap['mirrorHealthCacheHitRate'], equals(1.0));
    });
  });
}
