import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BandwidthArbiter Tests', () {
    test('BandwidthArbiter splits 70/30 when both HTTP and Torrents are active',
        () {
      final arbiter = BandwidthArbiter();
      const totalLimit = 1000000; // 1 MB/s

      final (httpLimit, torrentLimit) = arbiter.arbitrate(
        httpActiveCount: 2,
        torrentActiveCount: 1,
        totalLimitBps: totalLimit,
      );

      expect(httpLimit, 700000);
      expect(torrentLimit, 300000);
      expect(arbiter.httpGovernor.globalBytesPerSecond, 700000);
    });

    test('BandwidthArbiter grants 100% to HTTP when torrents are idle', () {
      final arbiter = BandwidthArbiter();
      const totalLimit = 1000000;

      final (httpLimit, torrentLimit) = arbiter.arbitrate(
        httpActiveCount: 2,
        torrentActiveCount: 0,
        totalLimitBps: totalLimit,
      );

      expect(httpLimit, 1000000);
      expect(torrentLimit, 0);
    });
  });
}
