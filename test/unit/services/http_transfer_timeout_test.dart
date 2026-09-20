import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HttpTransferJob Hard Timeout Computation', () {
    test('computes correct timeouts across file size orders of magnitude', () {
      const oneMB = 1 * 1024 * 1024;
      const hundredMB = 100 * 1024 * 1024;
      const oneGB = 1 * 1024 * 1024 * 1024;
      const tenGB = 10 * 1024 * 1024 * 1024;
      const hundredGB = 100 * 1024 * 1024 * 1024;

      // Documented baseline (FIX 13): 50 KB/s, clamped to [30 min, 24 h].
      // 1 MB -> ~21s, raised to the 30-minute floor
      final timeout1MB = HttpTransferJob.computeHardTimeoutForSize(oneMB);
      expect(timeout1MB, const Duration(minutes: 30));

      // 100 MB -> 2048s (~34 min), above the floor so unclamped
      final timeout100MB = HttpTransferJob.computeHardTimeoutForSize(hundredMB);
      expect(timeout100MB, const Duration(seconds: 2048));

      // 1 GB -> 1 GB / 50 KB/s = 20971s (~5h 49m)
      final timeout1GB = HttpTransferJob.computeHardTimeoutForSize(oneGB);
      expect(timeout1GB.inSeconds, 20971);

      // 10 GB -> ~58h, capped at 24h
      final timeout10GB = HttpTransferJob.computeHardTimeoutForSize(tenGB);
      expect(timeout10GB, const Duration(hours: 24));

      // 100 GB -> capped at 24h
      final timeout100GB = HttpTransferJob.computeHardTimeoutForSize(hundredGB);
      expect(timeout100GB, const Duration(hours: 24));
    });

    test('returns max timeout for unknown/zero size', () {
      expect(HttpTransferJob.computeHardTimeoutForSize(0),
          const Duration(hours: 24));
      expect(HttpTransferJob.computeHardTimeoutForSize(-1),
          const Duration(hours: 24));
    });
  });
}
