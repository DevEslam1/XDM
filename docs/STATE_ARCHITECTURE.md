# DMX Download State Architecture

## Overview
DMX utilizes a Clean Architecture model with event-driven state transitions, a centralized domain state machine, per-task actor mailboxes with generation counters, and durable disk journal reconciliation.

`
+-------------------------------------------------------------+
¦                     Presentation Layer                      ¦
¦        (Widgets, Notifiers, Screen Consumer/Builders)       ¦
+-------------------------------------------------------------+
                               ¦ Dispatches Commands / Listens to Granular Notifiers
                               ?
+-------------------------------------------------------------+
¦                       Providers                             ¦
¦     (DownloadProvider, DownloadListProvider, QueueEngine)   ¦
+-------------------------------------------------------------+
                               ¦
                               ?
+-------------------------------------------------------------+
¦                      Domain Layer                           ¦
¦  - TaskExecutor (Single-Flight Reducer & Command Dispatcher)¦
¦  - TaskMailbox (Actor Queue with Monotonic Epochs)          ¦
¦  - DomainStateMachine (Strict Matrix Invariants)            ¦
¦  - TaskStateMapper (Exhaustive Enum Conversions)            ¦
+-------------------------------------------------------------+
                               ¦ State Events / Snapshots
                               ?
+-------------------------------------------------------------+
¦                       Data Layer                            ¦
¦  - DriftTaskSnapshotStore (WAL & Database Persistence)      ¦
¦  - StateStore / DownloadJournal (.dmxstate & .dmxdone)      ¦
+-------------------------------------------------------------+
`

---

## 1. Canonical State Diagram & Mappings

The domain state machine defines the following canonical states:

`mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Queued: Enqueue / Schedule
    Queued --> Starting: Admission from Queue
    Starting --> Downloading: Connection Established
    Downloading --> Paused: User Pause / Power Loss / Net Loss
    Paused --> Queued: Resume Task
    Downloading --> Merging: Audio/Video Stitch
    Merging --> Completed: Finalize File
    Downloading --> Completed: Download Finished
    Downloading --> Failed: Error / Cancel / Connection Drop
    Failed --> Queued: Retry Task
    Completed --> [*]
    Failed --> [*]
`

### State Enum Mapping Matrix
Mapping between DomainDownloadState, DownloadStatus, and CycleState is exhaustive with zero default fallthrough:

| DomainDownloadState | DownloadStatus | CycleState | Notes |
| :--- | :--- | :--- | :--- |
| idle | queued | dormant | Initial unadmitted task state |
| queued | queued | queued | Waiting in execution queue |
| starting | downloading| llocating | In-flight connection handshake |
| downloading | downloading| downloading| Active byte transfer |
| paused | paused | paused | Stopped by user or policy |
| merging | merging | merging | Transcoding or multiplexing |
| completed | completed | completed | Verified file on disk |
| ailed | ailed | error | Transfer error or cancelled |

---

## 2. Command Catalog

All task lifecycle changes are modeled as immutable commands dispatched through TaskExecutor.dispatch():

### Task Commands (TaskCommand)
- StartTask(id, {ignoreQueueLimit}): Initiates transfer handshake via engine.
- PauseTask(id, {reason, userInitiated}): Halts transfer and persists pause reason.
- ResumeTask(id): Re-enqueues task into admission queue.
- CancelTask(id, {deleteFiles}): Cancels in-flight transfer and cleans up handles.
- DeleteTask(id, {deleteFiles}): Atomically marks mailbox tombstone, drops state machines, and cleans disk files.
- RetryTask(id): Resets error state and re-enqueues for download.
- ScheduleFired(id): Dispatched when OS or dynamic timer triggers a scheduled transfer.
- TorrentStatsTick(id, stats): Feeds live torrent swarm metrics to state store.
- UpdateTaskUrl(id, url): Refreshes expired media streaming links.
- SetTaskPriority(id, priority): Adjusts admission priority in the queue.

### Global System Commands (GlobalCommand)
- QueuePump(): Evaluates pending queue items against concurrency limits.
- NetworkChanged(isConnected, isWifi): Triggers network pause/resume policies.
- AppLifecycleChanged(state): Synchronizes foreground/background persistence.
- ReorderQueue(taskIds): Persists user-defined manual queue order.

---

## 3. Concurrency & Actor Mailbox Model

To eliminate data races and split-brain states:
1. **Per-Task Serialization**: Each task ID maps to an isolated TaskMailbox. Commands for the same task execute strictly sequentially.
2. **Generation / Epoch Counters**: Every state transition increments mailbox.generation. Asynchronous callbacks from previous generations or cancelled workers are discarded immediately (mailbox.isGenerationValid(gen)).
3. **Tombstone Registration**: When a task is deleted, TaskExecutor adds the task ID to _tombstones and marks mailbox.markTombstone(). Late async events or database snapshots can never resurrect deleted tasks.
4. **Single Concurrency Engine**: DownloadQueueEngine alone governs queue ordering, priority boosts, and concurrency slots (maxConcurrentDownloads).

---

## 4. Dispose-Order Contract

Components must be disposed in a deterministic hierarchy to prevent leaks and dangling async callbacks:

`
Step 1: Detach external listeners
        - SettingsProvider.removeListener()
        - PowerMonitor.removeListener()
Step 2: Cancel polling and retry timers
        - _eventSubscription.cancel()
        - _widgetUpdateTimer.cancel()
        - _torrentPollingTimer.cancel()
        - _retryTimers.values.cancel()
Step 3: Dispose child services & coordinators
        - NotificationCoordinator.dispose()
        - ScheduleManager.dispose()
        - NetworkMonitor.dispose()
Step 4: Drain and close domain engines & executors
        - DownloadOrchestrator.dispose()
        - TaskExecutor.dispose() (closes all mailboxes and state machines)
Step 5: Dispose granular UI value notifiers
        - Progress and speed ValueNotifiers disposed & cleared
Step 6: Super dispose
        - super.dispose()
`

---

## 5. WAL & Recovery Model

1. **State Store WAL**: Active chunk bytes are persisted incrementally in .dmxstate files.
2. **Atomic Completion Marker (.dmxdone)**: On final chunk completion and rename, worker flushes a .dmxdone marker. Startup reconciliation recognizes this marker even if process kill occurred before database commit, recovering 100% of unknown-length files with zero byte loss.
3. **Journal Cleanup**: On successful startup replay or task deletion, all associated journal and metadata files are cleanly unlinked.
