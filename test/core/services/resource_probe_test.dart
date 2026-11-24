import 'package:dmx/core/domain/repositories/diagnostic_repository.dart';
import 'package:dmx/core/services/resource_probe.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';

class _MockDiagnosticRepository extends Mock implements DiagnosticRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final probe = ResourceProbe.instance;

  setUp(() {
    probe.stop();
    probe.clear();
  });

  tearDown(() {
    probe.stop();
    probe.clear();
    if (GetIt.instance.isRegistered<DiagnosticRepository>()) {
      GetIt.instance.unregister<DiagnosticRepository>();
    }
  });

  group('ResourceProbeSample', () {
    test('csvHeader is stable', () {
      expect(
        ResourceProbeSample.csvHeader(),
        'timestamp,rss_bytes,isolate_bytes_transferred,'
        'p95_progress_latency_ms,db_write_queue_depth,widget_bridge_pushes',
      );
    });

    test('toCsvRow formats all fields', () {
      final sample = ResourceProbeSample(
        timestamp: DateTime.utc(2020, 1, 1),
        rssBytes: 1,
        isolateBytesTransferred: 2,
        p95ProgressLatencyMs: 3.14159,
        dbWriteQueueDepth: 4,
        widgetBridgePushes: 5,
      );
      expect(sample.toCsvRow(), contains('1,2,3.14,4,5'));
    });
  });

  group('ResourceProbe', () {
    test('exposes the soak scenario protocol text', () {
      expect(ResourceProbe.soakScenarioProtocol, contains('Soak Benchmark'));
    });

    test('sampleNow appends a sample', () {
      final before = probe.sampleCount;
      final sample = probe.sampleNow();
      expect(probe.sampleCount, before + 1);
      expect(sample.timestamp, isNotNull);
    });

    test('sampleNow reads registered DiagnosticRepository metrics', () {
      final repo = _MockDiagnosticRepository();
      when(() => repo.isolateBytesTransferred).thenReturn(11);
      when(() => repo.p95ProgressLatencyMs).thenReturn(2.5);
      when(() => repo.currentDbWriteQueueDepth).thenReturn(3);
      GetIt.instance.registerSingleton<DiagnosticRepository>(repo);

      final sample = probe.sampleNow();
      expect(sample.isolateBytesTransferred, 11);
      expect(sample.p95ProgressLatencyMs, 2.5);
      expect(sample.dbWriteQueueDepth, 3);
    });

    test('sampleNow tolerates a throwing repository', () {
      final repo = _MockDiagnosticRepository();
      when(() => repo.isolateBytesTransferred).thenThrow(StateError('boom'));
      GetIt.instance.registerSingleton<DiagnosticRepository>(repo);

      expect(() => probe.sampleNow(), returnsNormally);
    });

    test('recordWidgetPush increments the sampled push counter', () {
      probe.recordWidgetPush();
      probe.recordWidgetPush();
      final sample = probe.sampleNow();
      expect(sample.widgetBridgePushes, 2);
    });

    test('start is idempotent and stop halts sampling', () {
      probe.start(interval: const Duration(milliseconds: 10));
      expect(probe.isRunning, isTrue);
      probe.start(interval: const Duration(milliseconds: 10));
      expect(probe.isRunning, isTrue);
      probe.stop();
      expect(probe.isRunning, isFalse);
    });

    test('sampling loop takes samples on the timer', () {
      fakeAsync((async) {
        probe.clear();
        probe.start(interval: const Duration(milliseconds: 10));
        async.elapse(const Duration(milliseconds: 35));
        expect(probe.sampleCount, greaterThanOrEqualTo(3));
        probe.stop();
      });
    });

    test('ring buffer caps at maxCapacity', () {
      probe.clear();
      for (var i = 0; i < ResourceProbe.maxCapacity + 5; i++) {
        probe.sampleNow();
      }
      expect(probe.sampleCount, ResourceProbe.maxCapacity);
    });

    test('exportCsv writes the header and every sample', () {
      probe.clear();
      probe.sampleNow();
      final csv = probe.exportCsv();
      expect(csv, contains(ResourceProbeSample.csvHeader()));
      expect(csv.trim().split('\n').length, 2);
    });

    test('clear removes samples and resets the push counter', () {
      probe.sampleNow();
      probe.recordWidgetPush();
      probe.clear();
      expect(probe.sampleCount, 0);
      expect(probe.sampleNow().widgetBridgePushes, 0);
    });
  });
}
