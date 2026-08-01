import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/bandwidth_governor.dart';

void main() {
  group('Engine Performance Benchmarks', () {
    test('Journal CRC32 benchmark (10,000 operations)', () {
      final stopwatch = Stopwatch()..start();
      final data = List<int>.generate(1024, (i) => i % 256);
      for (var i = 0; i < 10000; i++) {
        DownloadJournal.crc32(data);
      }
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });

    test('Bandwidth governor token acquisition throughput', () async {
      final governor = BandwidthGovernor(10 * 1024 * 1024);
      governor.registerConsumer();
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 1000; i++) {
        await governor.acquire(1024);
      }
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(500));
    });
  });
}
