# Plan 03 — Persistence & Data-Loss Elimination

**Priority: P0/P1** (prevents re-downloads and inconsistent DB/file state)
**Current score: 7.0/10 → target 9.5+/10**

The persistence design is genuinely solid: a real CRC32-checked write-ahead journal, atomic tmp→fsync→rename snapshots, journal replay on startup, disk reconciliation, and demotion of interrupted "downloading" rows to paused. There is **no catastrophic whole-download-loss bug** in the common path. The gap to 9.5 is a set of edge windows and one architectural confusion (a dormant second writer).

## Architecture (verified)

Three independent persistence tiers, not one authority:
- **Download list + status:** Drift SQLite `download_tasks` (`app_database.dart:268-345`), loaded into `DownloadProvider._tasks`.
- **Byte-accurate HTTP progress:** `.dmxstate` snapshot + `.journal` WAL per task (`download_journal.dart`) — authoritative over the DB during a live download.
- **Torrent progress:** libtorrent fast-resume blobs (`torrent_resume_store.dart`) — but see Plan 02 C1, these are currently starved (fast-resume is stubbed).

## Verified findings (evidence)

| ID | Sev | Finding | Evidence |
|---|---|---|---|
| H1 | HIGH | **Unknown-size finalize gap.** `_finalize` renames temp→final, then **deletes** `.dmxstate`/`.journal`. DB `completed` is committed later by the main isolate. If killed in between AND `fileSize==0` (no Content-Length), startup reconciliation can't detect completion (`fileSize>0` guard) → **whole file re-downloaded** though it sits complete on disk. | `http_transfer_job.dart:2069-2072`; `download_provider.dart:311-319` |
| H2 | HIGH | **Dual writer / dead batcher.** `DownloadProvider` (live) and `DownloadListProvider` (dormant) both persist to the same rows. The debounced `saveTaskDebounced` batcher is **dead in production**; the moment anything calls `DownloadListProvider.load()` you get last-write-wins clobber. | `download_provider.dart` vs `download_list_provider.dart`; `database_service.dart:228-335`; `main.dart:491-495` |
| M1 | MED | **Screen-off journaling blackout.** WAL writes are skipped entirely when screen-off, and snapshot saves skip <5MB deltas. Combined with the 15s bg interval, a screen-off kill loses up to ~5MB / 15s of progress (resume still works — re-download of the tail). | `download_journal.dart:971-974,549-554`; `http_transfer_job.dart:2129-2131` |
| M2 | MED | **Silent save-failure swallowing.** `StateStore.save` wraps everything in `catch{debugPrint}`; no telemetry, no user error. (Same root as Plan 01 M-4.) | `download_journal.dart:643-645` |
| M3 | MED | **Cross-isolate writes not lock-serialized.** The worker isolate and main isolate both write `.dmxstate`; the `Lock`s are per-isolate. Safety rests only on atomic rename + "one active writer" convention. | `download_journal.dart:32-62`; `http_transfer_job.dart:59` |
| M4 | MED | **No DB downgrade path.** `schemaVersion=27`, additive `onUpgrade` only; over-version just warns. Installing an older build over a newer schema can brick the task DB. | `app_database.dart:554-555,1027-1030` |
| M5 | MED | **Completed-but-missing files not reconciled at startup** (reconcile loop skips completed). Shows "completed" with a dead path until the user opens it. | `download_provider.dart:300-302` |
| L1 | LOW | `SharedPrefsBatcher.dispose()` fires an un-awaited async flush; abrupt exit loses staged telemetry (not user data/progress). | `shared_prefs_batcher.dart:96-98` |
| L2 | LOW | ~69 `catch(_){}` in `core/services`, densest in durability paths — indistinguishable from real failures. | `download_journal.dart`, `torrent_resume_store.dart`, `http_transfer_job.dart` |
| L3 | LOW | Dead code: `TorrentResumeStore.persistTaskMapping`/`loadTaskMapping` never called. | `torrent_resume_store.dart:464-481` |

## Tasks

### Task 3.1 — Close the unknown-size finalize gap (H1) — do first
Two independent fixes, do both:
- **Order of operations:** don't delete `.dmxstate`/`.journal` in `_finalize` until the main isolate acknowledges the DB `completed` commit. Options: (a) have `_finalize` leave the WAL in place and let the main isolate delete it after the DB write (`drift_task_snapshot_store.dart:50-57`); or (b) write a tiny `.done` marker atomically before removing the WAL, and have startup treat `.done` + renamed final file as completed.
- **Record final byte count for unknown-size:** on completion, persist the measured final size into the task row so `download_provider.dart:311` can detect completion without the `fileSize>0` precondition.

### Task 3.2 — Resolve the dual-provider architecture (H2)
- Decide the single source of truth. Recommended: keep `DownloadProvider` as the sole writer; **delete** `DownloadListProvider` + the `saveTaskDebounced`/`_dbBatchTimer`/`_pendingProgressSaves` batcher (`database_service.dart:228-335`) since it's dead, OR fully migrate to it. Do not ship two.
- If keeping both temporarily, add a guard/assert that only one is populated, and make the app-background flush path actually flush the live provider (today `app_lifecycle_coordinator.dart:130-134` flushes DB+journals but the batcher is dead for the live provider).

### Task 3.3 — Bound the screen-off blackout (M1)
- Keep a low-frequency **forced** heartbeat even when `PowerMonitor.screenOff`: e.g. `recordChunkProgress(..., force:true)` and a durable snapshot every ≥N seconds or ≥1MB, so a screen-off kill loses seconds, not ~5MB. Tune for battery (a forced fsync every 30–60s is negligible).

### Task 3.4 — Stop swallowing persistence failures (M2, L2)
- Shared with Plan 01 Task 1.8. Route `StateStore.save`, journal fsync, and rename-fallback failures through `CrashReportingService`/`DiagnosticService` with counters; set a `persistenceDegraded` task flag after repeated failures; retry with backoff. Convert the load-bearing `catch(_){}` in durability paths to logged catches.

### Task 3.5 — Cross-isolate write safety (M3)
- Add a single-writer token or OS-level lockfile per `.dmxstate` path so a resume/retry on the main isolate can't interleave a stale snapshot over a newer one written by a still-shutting-down worker. At minimum, gate main-isolate writes on confirmation the worker has exited.

### Task 3.6 — DB downgrade guard (M4)
- Implement `onDowngrade` (or a `beforeOpen` version check) that refuses to open / creates a timestamped backup rather than letting Drift assert. Never silently drop the task DB.

### Task 3.7 — Reconcile completed-but-missing at startup (M5)
- In the startup reconcile, also verify completed tasks' files exist; if missing, call the existing `markCompletedFileMissing` (`download_provider.dart:876-882`) so the UI is truthful immediately, not on next open.

### Task 3.8 — Minor cleanups (L1, L3)
- Await/flush `SharedPrefsBatcher` on lifecycle-background (add to `app_lifecycle_coordinator`), or accept the telemetry-only loss and document it.
- Delete dead `persistTaskMapping`/`loadTaskMapping`.

## Acceptance criteria (9.5 bar)

- Kill the app at any point during an **unknown-size** download that just finished → on relaunch it's `completed`, not re-downloading.
- Only one code path writes `download_tasks`; no dead batcher.
- Screen-off kill loses ≤ a few seconds of progress.
- Every persistence failure is observable (telemetry + degraded flag); none silent.
- Downgrading the app never corrupts/bricks the DB.
- No completed task ever shows a live "open" affordance for a missing file.

## Test plan

1. Unknown-size finalize race test: inject a kill between rename and DB commit; assert relaunch = completed (Task 3.1).
2. Single-writer test: assert `DownloadListProvider` is gone or provably unpopulated (Task 3.2).
3. Screen-off heartbeat test: simulate `screenOff` + kill; assert lost bytes ≤ threshold (Task 3.3).
4. Downgrade test: open a v27 DB with a v-lower schema build; assert graceful refusal/backup (Task 3.6).
5. Missing-file reconcile test (Task 3.7).

## Effort / risk

- Task 3.1 and 3.2 are the meaningful ones — ~2–3 days each, medium risk (touch finalize + provider architecture; well-covered by tests).
- 3.3–3.8 are ~1–2 days total, low risk.
