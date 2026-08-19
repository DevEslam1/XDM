/// Centralized numeric thresholds and durations shared across the download
/// engine, journal, and persistence layers.
///
/// Keeping these in one place makes the resource-tuning knobs auditable and
/// lets tests assert against named constants instead of magic numbers.
library;

/// Maximum number of download threads per transfer.
const int kMaxTransferThreads = 16;

/// Minimum number of download threads per transfer.
const int kMinTransferThreads = 1;

/// A transfer smaller than this stays single-threaded.
const int kMinSizeForMultithread = 4 * 1024 * 1024; // 4MB

/// Multi-threaded transfers below this size get single-thread handling.
const int kMinSplitThreshold = 2 * 1024 * 1024; // 2MB

/// Hard timeout for a single HTTP task before it is killed by the watchdog.
/// Torrents are exempt from this timeout while active or seeding.
const Duration kTaskHardTimeout = Duration(hours: 24);

/// Global per-worker active task cap applied to engine IPC `limits`.
const int kWorkerMaxActiveJobs = 32;

/// Minimum bytes that must pass before a state save is considered.
const int kStateSaveMinBytes = 16 * 1024 * 1024; // 16MB

/// Journal compaction threshold (bytes) before rewriting a compressed line set.
const int kJournalCompactionThreshold = 512 * 1024;

/// Foreground chunk-progress journal write threshold.
const int kJournalForegroundWriteDelta = 512 * 1024;

/// Background (non-screen-off) chunk-progress journal write threshold.
const int kJournalBackgroundWriteDelta = 1 * 1024 * 1024; // 1MB

/// Screen-off chunk-progress journal write threshold.
const int kJournalScreenOffWriteDelta = 2 * 1024 * 1024; // 2MB

/// Maximum number of chunk-progress entries tracked in the journal LRU.
const int kJournalMaxBgRecordedEntries = 256;

/// State-save debounce interval while in the background.
const Duration kStateSaveBgInterval = Duration(seconds: 30);

/// State-save debounce interval while in the foreground.
const Duration kStateSaveFgInterval = Duration(seconds: 30);

/// Minimum background state-save delta.
const int kStateSaveBgDelta = 2 * 1024 * 1024; // 2MB

/// Minimum foreground state-save delta.
const int kStateSaveFgDelta = 2 * 1024 * 1024; // 2MB

/// Max cached state payloads kept for fast-fingerprint dedup.
const int kStateCacheMaxPayloads = 16;

/// Connectivity and I/O probe sample size.
const int kProbeSampleSize = 64 * 1024;

/// Above this per-task speed the writer buffer is enlarged.
const int kHighSpeedBpsThreshold = 50 * 1024 * 1024;

/// Large writer buffer used for high-speed transfers.
const int kWriterBufferLarge = 512 * 1024;

/// Default writer buffer.
const int kWriterBufferDefault = 256 * 1024;

/// Above this buffered delta (per task) a full buffer flush is triggered.
const int kPositionalWriterFlushThreshold = 4 * 1024 * 1024;

/// Memory-pressure threshold below which the pool evicts idle clients.
const int kMemoryPressureEvictBytes = 100 * 1024 * 1024;

/// Session of download history retained by default.
const int kHistoryRetentionDays = 7;
