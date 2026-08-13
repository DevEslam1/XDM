# Download Manager — Production-Readiness Audit

Scope: download orchestration + torrent stack in `lib/features/downloads` and `lib/core/services`.
All findings cite `file:line`.

Files audited (line counts):
- `download_orchestrator.dart` (4118)
- `download_provider.dart` (5166)
- `download_task.dart` (751)
- `torrent_service_ffi.dart` (1303)
- `download_journal.dart` (691)
- `download_backup_mixin.dart` (491)
- `notification_coordinator.dart` (438)
- `download_filter_mixin.dart` (319)
- `download_queue_mixin.dart` (301)
- `network_monitor.dart` (247)
- `schedule_manager.dart` (245)
- `torrent_resume_store.dart` (223)
- `torrent_service_stub.dart` (130)
- `download_metrics.dart` (123)
- `download_filter_provider.dart` (82)
- `download_torrent_mixin.dart` (595)
- wiring: `download_coordinator.dart` (40), `download_list_provider.dart` (41), `download_queue_provider.dart` (44), `torrent_provider.dart` (24)

---

## 1. State machine

**States** (`download_task.dart:32-39`): `queued, downloading, paused, completed, failed, merging`.

**Legal transitions observed:**
- `add*` → `queued` (tasks enter the list queued; there is no `created` state).
- `queued` → `downloading` via `pumpQueue` → `startTaskFromQueue` → orchestrator `_startTaskBody`.
- `downloading` → `completed` (orchestrator finalize path, `_mergeAudioVideo` / `finalizeDownload`).
- `downloading` → `paused` (user, network/wifi loss, battery saver, torrent queue enforcement).
- `paused` → `queued` (schedule promotion, network recovery) or `paused` → `downloading` (resume).
- `failed` → `queued` (retry / start-over, `retryTask`, `startOverTask`).
- `downloading` → `merging` → `completed` (YouTube video+audio merge, orchestrator `_mergeAudioVideo`).
- Any active state → `failed` (transport error, integrity error, torrent engine error state).

**Protection layer** lives in `_mergeTaskUpdate` (`download_provider.dart:3416-3455`):
- Terminal-state guard: `completed` is never overwritten by a non-completed incoming update.
- C3: a `pausedByUser` task is never silently promoted to `queued`/`downloading` by async updates.
- H5: `paused`/`failed`/`merging` is protected from stale `downloading` snapshots.
- F7: an incoming update that explicitly zeroes progress (reset) is always accepted.
- Progress ticks during active download keep the max of both `downloadedBytes` and `audioProgress`.

**Findings:**
- [MEDIUM] **`failed` is not terminal.** Only `completed` has a terminal guard in `_mergeTaskUpdate`. A retry that re-queues a failed task is legitimate, but a *stale* async snapshot can overwrite a `failed` status with `queued`/`downloading` (the H5 guard covers `downloading` only, not `queued`). The `_runGuardedTaskOperation` debounce (`download_provider.dart:187-236`) mitigates, but there is no state-guard equivalent for `failed`.
- [LOW] **`audioProgress` can regress on merging transitions.** `isProgressTick` requires *both* sides `downloading` (`download_provider.dart:3441`). A `downloading → merging` tick therefore bypasses the max() merge and trusts the incoming `audioProgress` unconditionally; a stale tick captured before the audio finished would regress the audio bar during the merge phase.
- [LOW] **State recovery** on DB load maps unknown statuses to `paused` (`download_task.dart:613-615`); orphan downloads (interrupted at close) are transitioned to `queued`/`paused` with the `pausedOrphaned` message (`download_provider.dart` load path). Correct, but relies on the load-time `_mergeTaskUpdate` semantics being skipped for freshly loaded tasks — verify no `_setTask` merge is applied to the initial DB batch (it is applied directly via `_tasks` population, so no regression risk).

**Overall:** the state machine is well-guarded. The main gap is the absence of an explicit `failed` terminal guard and the audio-progress edge in `_mergeTaskUpdate`.

---

## 2. Race conditions

**Guards present:**
- `_runGuardedTaskOperation` (`download_provider.dart:187-236`): in-flight dedupe map `_inFlightTaskOps` + 350 ms debounce `_lastTaskOpTimes` for pause/resume/retry; `notifyListeners` fired at op start and end.
- Per-task DB save serialization: `_dbSaveQueues` chain (`download_provider.dart:3694-3727`) ensures structural saves never interleave for the same task.
- `pumpQueue` re-entrancy: `_queueProcessing` + `_needsRePump` + `_pendingMaxConcurrentOverride` (`download_queue_mixin.dart:131-230`, QUEUE-FIX-7).
- Torrent tracking started exactly once: `_trackingCompleter` guard (`torrent_service_ffi.dart:505-515`).
- Notification action double-tap dedupe: 500 ms `_lastNotifActionTime` (`notification_coordinator.dart:220-229`).
- Network monitor re-entry: `_checkingNetwork` + deferred recheck microtask FIX(C-H4) (`network_monitor.dart:88-129`).
- Torrent `startSeedingTorrent` B3 checks `isTorrentAlive` before re-adding a handle; FIX-02 removes error-state handles (`download_torrent_mixin.dart:41-70`).

**Findings:**
- [HIGH] **Direct `_tasks[i]` mutations bypass `_mergeTaskUpdate`.** The torrent update stream writes `_tasks[taskIdx]` directly (`download_provider.dart:274-310`, FIX T-5 uploadedBytes sync) and `updateSeedingSpeeds` writes `providerTasks[i]` directly (`download_torrent_mixin.dart:279-327`). These are same-isolate, so no true data race, but they bypass the clamp/merge invariants (`_setTask` clamps `downloadedBytes`, `audioProgress`, chunks). The uploadedBytes write is benign; the seeding-speed write sets `speed` from native stats which is intended. Recommend routing through a merge-aware setter for consistency.
- [MEDIUM] **Torrent error → failed is dropped if a concurrent `_setTask` is in flight.** The stream handler checks `task.status == DownloadStatus.downloading` before failing it (`download_provider.dart:299-310`). A pause that raced just before the error check leaves the torrent in `paused` with a native error state; it will be caught on the next `startSeedingTorrent` (FIX-02) only if resumed. Acceptable, but the window exists.
- [LOW] `exitApp` (`download_provider.dart:2599-2685`) calls `pauseAllTasks` then `exit(0)` after 400 ms. Pending `_pendingProgressUpdates` are not flushed (`_flushPendingProgress` is not awaited on this path) — up to ~5 s of progress is lost on app exit from the notification action. The periodic resume-save and the 400 ms wait mitigate, but a targeted flush before exit is missing.
- [LOW] `startOverTask` awaits the active future with a 5 s timeout and proceeds anyway (`download_provider.dart:4816-4826`) — a leaked future could allow the old engine instance to keep writing while the new one starts. Mitigated by cancel-token cancellation, but the window is untested.

---

## 3. notifyListeners frequency

**Throttles present:**
- Batch mode: `startBatch`/`endBatch`/`markBatchDirty`; `notifyListeners` override defers during batch (`download_provider.dart:592-620`). Used by `mixinPauseAllTasks`/`mixinResumeAllTasks` (`download_queue_mixin.dart:232-275`).
- Progress ticks throttled in `_pushTick` (FIX-AUDIT-E1, `download_provider.dart:388-410`): minimum delta 0.005 progress / 1024 bytes speed.
- Progress-only `_setTask` calls set `_notifyPending` and are coalesced to the widget timer cadence (~5 s; 10 s aggressive; 15 s screen-off) (`download_provider.dart:3730-3740`, timer at `_startWidgetTimer`).
- Structural changes call `notifyListeners` **after** the DB write succeeds, so UI and persistence stay consistent (`download_provider.dart:3720`).
- Torrent seeding speed sync notifies at most once per widget-timer tick via `updateSeedingSpeeds()` return value (`download_provider.dart` timer body).
- Notification progress posts throttled to 1 s (screen-on) / 5 s (screen-off) (`notification_coordinator.dart:341-350`); group summary ≤1/3 s (`notification_coordinator.dart:374-390`).
- Filter setters (`download_filter_mixin.dart:221-298`) notify on each user action — acceptable.

**Findings:**
- [LOW] **Torrent update stream does not notifyListeners directly** (good), but `checkTorrentRatioLimits` and `enforceTorrentQueue` (`download_torrent_mixin.dart:467-594`) can call `providerNotifyListeners()` on *every* torrent update if a pause/stop-seed occurs — the stream fires on every native libtorrent update. This is bounded by actual policy triggers, but a task near a ratio/queue boundary could cause repeated notifications. Consider a 1 s min-interval in `checkTorrentRatioLimits`.
- [LOW] `filteredTasksDirty` is correctly **not** set on progress ticks (`download_provider.dart:3713-3725`), so the filtered list cache is preserved. Good.
- [INFO] Overall the notify frequency discipline is strong — this is the best section in the codebase.

---

## 4. Persistence

**Crash-safe stores:**
- `TorrentResumeStore` (`torrent_resume_store.dart`): keyed by source URL / info-hash (stable across restarts, `_stableKey`), tmp → fsync → rename for both blob and metadata, SHA-256 embedded in metadata and re-verified on load; corrupt blobs are deleted and degrade to a recheck (never undefined engine state). `saveAndWait` is the "pause implies resume-data-flushed" barrier (`torrent_resume_store.dart:85-131`).
- `DownloadJournal` (`download_journal.dart:474-668`): append-only JSONL with a `synchronized` lock, init/chunk/checkpoint records, compaction at 512 KB (reduced from 2 MB for mobile), recovery replays to the last checkpoint; CRC32 helper.
- `StateStore` (`.dmxstate`) v3 (`download_journal.dart:203-463`): atomic tmp+rename, fsync, v2 migration, disk reconciliation (truncates oversized files, clamps chunk bytes, zeroes state when the temp file is missing).
- `_setTask` save path: per-task serialized saves, exponential-backoff retry on failure (5 attempts, jittered up to 30 s, `_scheduleDbRetry` at `download_provider.dart:3752-3800`), `lastSaveError` ValueNotifier for UI surfacing, in-memory task stays authoritative on failure.
- `_flushPendingProgress` is re-entry-guarded by `_flushingIds`.

**Findings:**
- [MEDIUM] **Progress-only DB saves can be lost on force-kill.** Progress is persisted only via the 5 s widget-timer batch (`download_provider.dart:3776-3790`) plus `_pendingProgressUpdates`. A process kill between timer ticks loses the delta (up to 5 s of bytes). Torrent progress is protected by periodic resume-data saves; HTTP is not. This is a conscious trade-off (battery), but worth documenting as an explicit SLA.
- [LOW] `clearHistoryTasks` calls `TorrentService.removeTorrent(..., deleteFiles: false)` **without** `deleteResumeData: true` (`download_provider.dart:3270-3273`), unlike `deleteTask` which passes it. Leftover fast-resume blobs accumulate for removed history tasks. Use `deleteResumeData: true` (or `TorrentResumeStore.delete`) for consistency.
- [INFO] `addBatchDownloads` path-sanitization (`download_provider.dart:1278-1309`) is a good last-line-of-defense against path traversal.

---

## 5. Torrent session

**Lifecycle (`torrent_service_ffi.dart`):**
- State machine: `uninitialized → initializing → ready → pausing/disposing → disposed`. `init` guarded by `_initCompleter`; concurrent `init` calls share the same future; native init failure falls back to `uninitialized` with `isAvailable=false` (`torrent_service_ffi.dart:398-441`).
- `ready` getter awaits `init` for uninitialized state but **throws** `StateError` in `pausing`/`disposing` states (`torrent_service_ffi.dart:386-397`).
- `_CapabilityGate` probes every method once at init (fileProgress, filePriorities, saveResumeData, forceReCheck, trackers, createTorrent, loadIpFilter, sequential, superSeeding, pieceDeadline) and guards each call.
- Session config applied from settings (DHT, UPnP, encryption, connection limit, speed limits); DHT bootstrap nodes injected (`torrent_service_ffi.dart:456-503`).
- Update stream mapping: `_latestStats` + `_latestProgress` kept in sync; removed IDs pruned; FIX-22; `totalWantedDone` falls back to `totalDone` when `totalWanted == 0` (FIX-PCTG).
- `dispose` saves all resume data first (`saveAllResumeData`), then closes the session (`torrent_service_ffi.dart:703-1003` region).
- Seeding policy: pure `shouldStopSeeding` (ratio + max-seed-time), plus mixin `checkTorrentRatioLimits` / `enforceTorrentQueue` (`download_torrent_mixin.dart:467-594`).

**Findings:**
- [HIGH] **`checkTorrentRatioLimits` hardcodes `isCharging: true, isOnWifi: true`** (`download_torrent_mixin.dart:499-500`). The `SeedingPolicy` (`seedOnlyWhenCharging`, `seedOnlyOnWifi`) flags are therefore **never honored** — the policy only evaluates ratio + max-seed-time. A user who enables "seed only while charging / on Wi-Fi" gets seeding stopped on cellular or while unplugged. This is a real user-facing bug. See Logic bugs #1.
- [MEDIUM] `TorrentService.ready` throws in `disposing`/`pausing`; `hasResumeData` → `_readyOrThrow` would propagate during teardown. Callers during `exitApp`/provider dispose should not call into torrent APIs, but nothing enforces it; an accidental call during shutdown surfaces a `StateError`. Recommend returning a benign `null`/`false` instead of throwing in these states.
- [LOW] `enforceTorrentQueue` counts **seeding** torrents against `maxActiveDownloads` budget (`download_torrent_mixin.dart:542-547`) — a fully-seeded torrent consuming a slot can pause a *downloading* torrent if `activeDownloads > maxActiveDownloads`. Confirm this is intended (cap is downloads + seeds, not downloads only).
- [INFO] Capability-gated degrade paths are exemplary — every native call is try/caught and falls back to a reasonable default (empty list, null, false).

---

## 6. Schedule / network

**ScheduleManager (`schedule_manager.dart`):**
- Dynamic timer targeting the nearest future scheduled task (SCHED-FIX-3); falls back to 15 s. Timer re-arms only after the tick completes, preventing overlap (`schedule_manager.dart:82-118`).
- Promotion gate: `paused && !pausedByUser && scheduledAt in past` → `queued`, preserving `wasScheduledAt` (SCHED-FIX-1) and clearing error/completed markers.
- Save-failure isolation: each promotion saved independently; failed saves are reverted in-memory (SCHED-FIX-6), and the queue is not pumped on partial failure.
- `_ready` gate skips promotion until the provider finishes loading (SCHED-FIX-7); dispose guard in the promotion loop (SCHED-FIX-4).
- Periodic app-update check throttled to ≥12 h.
- Notification on schedule start (SCHED-FIX-5).

**NetworkMonitor (`network_monitor.dart`):**
- Subscribes to `onConnectivityChanged` and resolves initial connectivity before the queue pump.
- Two trackers: `_tasksPausedDueToDisconnect` and `_tasksPausedDueToWifiOnly`; re-entry guard + deferred recheck microtask (FIX(C-H4)).
- Pause path cancels the token and awaits the active future (5 s bound) before marking paused; wifi-only path skips the future-wait (comment says cancel-token removal handles resumes) — note the asymmetry.
- Resume path skips tasks with `pausedByUser` set.

**Findings:**
- [LOW] **Wifi-only resume can resurrect a user task.** `_resumeWaitingForWifi` matches tasks whose `errorMessage == waitingWifi` even if they were not added to `_tasksPausedDueToWifiOnly` (`network_monitor.dart:221-223`). If a user pauses such a task *without* `pausedByUser` being set (e.g. via queue enforcement), a later wifi reconnect can silently re-queue it. The `pausedByUser` guard covers user-initiated pauses; other pause paths can slip through.
- [LOW] Network pause marks the task `paused` with `waitingNetwork`; on recovery it goes to `queued` then `downloading` — but the task's original `statusMessage`/failure state isn't restored. Minor cosmetic.
- [INFO] Schedule + network logic is otherwise tight; the error handling (per-promotion save isolation, heartbeat on download activity) is production-quality.

---

## 7. Error handling

**Orchestrator mapping** (`download_orchestrator.dart` error-message region): user-friendly messages for `InsufficientStorageException`, `DownloadIntegrityException`, `IsolateSpawnTimeoutException`, and `DioException` status-code switch (403/401/404/410/416/500/503). `FailureCategory` (`download_task.dart:20-30`) carries a taxonomy: network, serverError, authError, diskFull, integrityError, fileChanged, mergeFailed, torrentError, unknown.

- Retry: `_retryTaskInternal` (provider) resets state for integrity/auth/410/404/"file changed"/expired families (deletes temp/state/journal sidecars), uses a merge-only retry for YouTube (YT-4).
- DB save failures: `lastSaveError` ValueNotifier + exponential-backoff retry (5 max) + in-memory authoritative task (never regress to stale DB data).
- Torrent engine error states → `failed` with the native label surfaced (`download_provider.dart:299-310`).
- Security: `deleteTask` blocks path traversal and root deletion (`download_provider.dart:3237-3266`); `addBatchDownloads` path-canonicalization guard.
- Import path: backup checksum verification, encrypted formats XDMCRYPT 1/2/3/4 with constant-time HMAC compare, legacy XOR downgrade is explicitly deprecated and warned.

**Findings:**
- [MEDIUM] **`_pushTick` speed threshold hides low-speed states.** Speed below 1024 B/s is not propagated (`download_provider.dart:388-410`), so the UI shows stale/non-updating speed for stalled-but-alive transfers; users may see a frozen card while `speedHistories` keep updating. This also affects the `ytLowSpeedCounts` stall detection inputs if they read `task.speed`.
- [LOW] Torrent error handling only fires for `downloading` tasks (`download_provider.dart:299-310`); a `paused`/`queued` torrent in a native error state is silent until resumed. Consider handling all non-terminal statuses.
- [LOW] `_resumeWaitingForWifi` and the network pause paths set `errorMessage` to `waitingWifi`/`waitingNetwork` but never `FailureCategory` — the taxonomy is incomplete on this path (category stays null). Minor, but affects any analytics/UI that keys off `failureCategory`.

---

## 8. Logic bugs (file:line)

1. **[HIGH] `checkTorrentRatioLimits` ignores charging/wifi settings** — `download_torrent_mixin.dart:499-500` hardcodes `isCharging: true, isOnWifi: true` when building the `SeedingPolicy`. `seedOnlyWhenCharging` / `seedOnlyOnWifi` settings have no effect. Fix: pass real `PowerMonitor`/`NetworkMonitor` state.
2. **[MEDIUM] `enforceTorrentQueue` counts seeds against `maxActiveDownloads`** — `download_torrent_mixin.dart:542-547`. A seeded torrent occupies a download slot and can pause an actively downloading torrent.
3. **[MEDIUM] `TorrentService.ready` throws during shutdown** — `torrent_service_ffi.dart:386-397` returns `Future.error(StateError)` in `pausing`/`disposing`. Callers during teardown (e.g. `hasResumeData`) get an unhandled async error.
4. **[MEDIUM] `_mergeTaskUpdate` audio regression on `downloading → merging`** — `download_provider.dart:3439-3449`: max() merge only applies when both sides are `downloading`.
5. **[LOW] `clearHistoryTasks` leaves torrent resume blobs behind** — `download_provider.dart:3270-3273` removes the native torrent without `deleteResumeData: true`, unlike `deleteTask`.
6. **[LOW] `_pushTick` drops speeds < 1 KB/s** — `download_provider.dart:388-410`; UI freezes on stalled transfers.
7. **[LOW] `updateTaskThreadCount` leaves an active task paused** — `download_provider.dart:3982-4040`: after pausing, cleaning part files, and resetting bytes, it sets `status: paused` and never calls `pumpQueue`; the task stays paused instead of resuming with the new thread count.
8. **[LOW] `startOverTask` audioBytes read can stall on `threadCount: 1` audio** — FIX-4 comment says small audio uses 1 thread and never writes `.dmxstate`; the read correctly falls back to `audioThreadCount > 0 ? ... : 1` (`download_provider.dart:4872-4880`) — verified correct, listed for regression awareness.
9. **[LOW] `progressPercentString` shows byte badge for unknown-size torrents but `progress` returns -1.0** — `download_task.dart:281-301`; consistent, but the -1.0 sentinel can leak into `WidgetDataBridge` if a consumer doesn't clamp (bridge clamps; verified).
10. **[INFO] `opaqueHandleFor` returns the real task ID** — `notification_coordinator.dart:127-129` documents bypassing the handle map; the persisted handle map is now dead code but still maintained (`_opaqueHandles`/`_taskToHandle`). Not a bug; cleanup candidate.

---

## 9. Production readiness

**Strengths (genuinely strong):**
- Aggressive defensive coding: every native call gated by `_CapabilityGate`; every async op try/caught with fallbacks; no bare rethrows on hot paths.
- Persistence is crash-safe end-to-end (resume store, journal, `.dmxstate`, DB save serialization + retry).
- notifyListeners discipline is well-engineered (batch mode, throttled ticks, structural-vs-progress separation, coalesced timer).
- State-machine guards (terminal state, C3, H5, F7) show real production scar-tissue from past bugs.
- Security: path-traversal guards, backup checksum + constant-time HMAC, deprecated insecure formats.
- The torrent session lifecycle (init/dispose guards, resume-data flush barrier) is production-grade.

**Readiness gaps to close before release:**
1. [Critical] `checkTorrentRatioLimits` charging/wifi settings silently disabled (logic bug #1) — violates documented user settings.
2. [High] Direct `_tasks[i]` writes bypassing merge invariants (race section #1) — mostly benign today, but a footgun for future edits; standardize on a single mutator.
3. [High] `exitApp` does not flush pending progress saves before `exit(0)` — data-loss window on the notification exit action.
4. [Medium] `TorrentService.ready` throwing during teardown — add benign-state handling.
5. [Medium] `enforceTorrentQueue` seed-vs-download slot semantics — confirm intended.
6. [Medium] Progress-persistence SLA undocumented (5 s loss window on force-kill for HTTP).
7. [Low] `_pushTick` speed threshold, `clearHistoryTasks` resume-blob leak, `updateTaskThreadCount` leaves tasks paused.
8. [Low] Dead code: handle-map indirection in `NotificationCoordinator`; duplicate filter system (`DownloadFilterProvider` vs `DownloadFilterMixin`).

**Verdict:** The codebase is in good shape for production. The top-3 items to fix are (1) the seeding charging/wifi settings bug, (2) a `_setTask`-style merge-aware single mutation path, and (3) a pre-exit progress flush. The remaining items are hardening/consistency, not blockers.

---

## Prioritized fix plan

### Critical
1. `download_torrent_mixin.dart:499-500` — feed real charging / wifi state into `SeedingPolicy` instead of hardcoded `true`/`true`; honor `seedOnlyWhenCharging` and `seedOnlyOnWifi` (needs `PowerMonitor`/`NetworkMonitor` access in the mixin).

### High
2. Introduce a single merge-aware mutation path (`_setTask` already exists); route `updateSeedingSpeeds` (`download_torrent_mixin.dart:279-327`) and the torrent-stream `uploadedBytes` write (`download_provider.dart:274-310`) through it (or an explicit merge helper) so invariants are applied uniformly.
3. `exitApp` (`download_provider.dart:2599-2685`): await `_flushPendingProgress` for all pending ids (with a short timeout) before the 400 ms `exit(0)`.

### Medium
4. `TorrentService.ready` (`torrent_service_ffi.dart:386-397`): return a completed/benign value instead of `Future.error` when `pausing`/`disposing`.
5. `enforceTorrentQueue` (`download_torrent_mixin.dart:542-547`): clarify/document or fix the seed-vs-download slot accounting (`maxActiveDownloads` should gate downloads; seeds gated separately or explicitly included by design).
6. `_mergeTaskUpdate` (`download_provider.dart:3439-3449`): extend the max() progress merge to `downloading → merging` transitions so `audioProgress` can't regress during merge.
7. Document the HTTP progress-persistence SLA (up to ~5 s lost on force-kill) and consider flushing on app-lifecycle `paused`/`detached` events.
8. Torrent error-state handling (`download_provider.dart:299-310`): also fail `queued`/`paused` torrents in native error state, not just `downloading`.

### Low
9. `_pushTick` (`download_provider.dart:388-410`): allow speed updates below 1 KB/s (e.g. report 0 once, then tiny increments) so stalled transfers don't freeze the UI.
10. `clearHistoryTasks` (`download_provider.dart:3270-3273`): pass `deleteResumeData: true` (or call `TorrentResumeStore.delete`) to avoid leaking resume blobs.
11. `updateTaskThreadCount` (`download_provider.dart:3982-4040`): call `pumpQueue()` after re-queueing so the task resumes with the new thread count.
12. Remove dead code: `NotificationCoordinator` handle-map indirection (`notification_coordinator.dart:82-142`) and the unused `DownloadFilterProvider` duplicate.
