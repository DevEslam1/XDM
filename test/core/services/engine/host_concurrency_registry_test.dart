import 'package:dmx/core/services/engine/host_concurrency_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HostConcurrencyProfile & Registry Tests', () {
    setUp(() {
      HostConcurrencyRegistry.instance.clear();
    });

    test(
        'HostConcurrencyProfile tracks speed and scales up on high performance',
        () {
      final profile = HostConcurrencyProfile('example.com', 4);
      expect(profile.optimalThreads, 4);

      // Record strong speed measurements (10 MB/s across 4 threads = 2.5 MB/s/thread)
      profile.recordSpeed(10 * 1024 * 1024, 4);
      expect(profile.avgSpeedPerThread, 2.5 * 1024 * 1024);

      // Stable high performance allows scale-up
      profile.recordSpeed(10 * 1024 * 1024, 4);
      expect(profile.optimalThreads, 5);
    });

    test(
        'HostConcurrencyProfile scales down when congestion drops throughput per thread',
        () {
      final profile = HostConcurrencyProfile('example.com', 8);
      profile.recordSpeed(16 * 1024 * 1024, 8); // 2 MB/s per thread

      // Severe drop in throughput per thread under load
      profile.recordSpeed(4 * 1024 * 1024, 8); // 0.5 MB/s per thread
      expect(profile.optimalThreads, lessThan(8));
    });

    test('HostConcurrencyRegistry extracts host and retrieves optimal threads',
        () {
      final reg = HostConcurrencyRegistry.instance;
      final t1 = reg.getOptimalThreadsFor('https://cdn.example.com/file.zip',
          maxLimit: 8);
      expect(t1, 4);

      reg.recordSpeed(
          'https://cdn.example.com/another.zip', 20 * 1024 * 1024, 4);
      reg.recordSpeed(
          'https://cdn.example.com/another.zip', 20 * 1024 * 1024, 4);
      final t2 = reg.getOptimalThreadsFor('cdn.example.com', maxLimit: 8);
      expect(t2, greaterThan(4));
    });
  });
}
