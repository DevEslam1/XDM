import 'package:dmx/core/services/diagnostic_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DiagnosticService Performance & Architecture', () {
    late DiagnosticService service;

    setUp(() {
      service = DiagnosticService();
      service.clear();
      service.resetTelemetryMetrics();
    });

    test('record maintains max entries bounded size', () {
      for (int i = 0; i < 300; i++) {
        service.record('TestArea', 'Log message $i');
      }
      expect(service.entries.length, lessThanOrEqualTo(200));
    });

    test('recordProgressLatency clamps queue and produces correct p95 latency',
        () {
      for (int i = 1; i <= 100; i++) {
        service.recordProgressLatency(Duration(milliseconds: i));
      }
      expect(service.p95ProgressLatencyMs, closeTo(95.0, 1.0));
    });

    test('recordIsolatePayloadSize saturates integer safely without overflow',
        () {
      service.recordIsolatePayloadSize(1000);
      service.recordIsolatePayloadSize(2000);
      expect(service.isolateBytesTransferred, equals(3000));
      expect(service.isolateMessageCount, equals(2));
    });

    test('telemetryMetricsSnapshot invalidates cache only when dirty', () {
      final snap1 = service.telemetryMetricsSnapshot();
      final snap2 = service.telemetryMetricsSnapshot();
      expect(identical(snap1, snap2), isTrue);

      service.recordIsolatePayloadSize(500);
      final snap3 = service.telemetryMetricsSnapshot();
      expect(identical(snap1, snap3), isFalse);
    });
  });
}
