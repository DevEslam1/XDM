import 'package:dmx/core/constants/thresholds.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('core/constants/thresholds', () {
    test('thread thresholds are ordered and consistent', () {
      expect(kMinTransferThreads, 1);
      expect(kMaxTransferThreads, 16);
      expect(kMinTransferThreads, lessThan(kMaxTransferThreads));
      expect(kMinSizeForMultithread, 4 * 1024 * 1024);
      expect(kMinSplitThreshold, 2 * 1024 * 1024);
      expect(kMinSplitThreshold, lessThan(kMinSizeForMultithread));
    });

    test('task and worker limits are positive', () {
      expect(kTaskHardTimeout, const Duration(hours: 24));
      expect(kWorkerMaxActiveJobs, 32);
      expect(kStateSaveMinBytes, 16 * 1024 * 1024);
    });

    test('journal thresholds increase foreground to screen-off', () {
      expect(kJournalCompactionThreshold, 512 * 1024);
      expect(kJournalForegroundWriteDelta, 256 * 1024);
      expect(kJournalBackgroundWriteDelta, 1 * 1024 * 1024);
      expect(kJournalScreenOffWriteDelta, 2 * 1024 * 1024);
      expect(
        kJournalForegroundWriteDelta,
        lessThan(kJournalBackgroundWriteDelta),
      );
      expect(
        kJournalBackgroundWriteDelta,
        lessThan(kJournalScreenOffWriteDelta),
      );
      expect(kJournalMaxBgRecordedEntries, 256);
    });

    test('state save intervals and deltas are consistent', () {
      expect(kStateSaveBgInterval, const Duration(seconds: 15));
      expect(kStateSaveFgInterval, const Duration(seconds: 5));
      expect(kStateSaveFgInterval, lessThan(kStateSaveBgInterval));
      expect(kStateSaveBgDelta, 2 * 1024 * 1024);
      expect(kStateSaveFgDelta, 512 * 1024);
      expect(kStateSaveFgDelta, lessThan(kStateSaveBgDelta));
      expect(kStateCacheMaxPayloads, 16);
    });

    test('buffer and memory thresholds are positive and ordered', () {
      expect(kProbeSampleSize, 64 * 1024);
      expect(kHighSpeedBpsThreshold, 50 * 1024 * 1024);
      expect(kWriterBufferLarge, 512 * 1024);
      expect(kWriterBufferDefault, 256 * 1024);
      expect(kWriterBufferDefault, lessThan(kWriterBufferLarge));
      expect(kPositionalWriterFlushThreshold, 4 * 1024 * 1024);
      expect(kMemoryPressureEvictBytes, 100 * 1024 * 1024);
    });

    test('retention and mirror/site limits are declared', () {
      expect(kHistoryRetentionDays, 0);
      expect(kMirrorMaxEntries, 200);
      expect(kMirrorMinFlushInterval, const Duration(minutes: 5));
      expect(kMirrorBlacklistTtl, const Duration(hours: 6));
      expect(kSiteReliabilityMaxEntries, 200);
      expect(kSiteReliabilityPersistInterval, const Duration(seconds: 60));
    });
  });
}
