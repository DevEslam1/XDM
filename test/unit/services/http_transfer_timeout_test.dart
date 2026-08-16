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

      // 1 MB -> bounded by min (30 min)
      final timeout1MB = HttpTransferJob.computeHardTimeoutForSize(oneMB);
      expect(timeout1MB, const Duration(minutes: 30));

      // 100 MB -> 1000s (~16.6m), bounded by min (30 min)
      final timeout100MB = HttpTransferJob.computeHardTimeoutForSize(hundredMB);
      expect(timeout100MB, const Duration(minutes: 30));

      // 1 GB -> 10,485s (~2h 54m 45s)
      final timeout1GB = HttpTransferJob.computeHardTimeoutForSize(oneGB);
      expect(timeout1GB.inSeconds, 10485);

      // 10 GB -> 100,000s (>24h), capped at 24h
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
