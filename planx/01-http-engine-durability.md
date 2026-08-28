# Plan 01 — HTTP Engine Durability & Correctness

**Priority: P0** (silent data corruption is the worst failure class for a download manager)
**Current score: 7.5/10 → target 9.5+/10**

The HTTP engine is genuinely good: real work-stealing isolate pool, real positional writes into one preallocated file, a CRC32-protected write-ahead journal, per-chunk + whole-file SHA-256, and real byte-delta speed/ETA. It is **not** fake. The gap to best-in-class is a small set of durability and correctness holes that let a hard power loss (or a defeated safety gate) mark an incomplete/corrupt file as "complete."

## Verified findings (evidence)

| ID | Sev | Finding | Evidence |
|---|---|---|---|
| C-1 | CRITICAL | Periodic save flushes OS buffers, not disk. `writer.flushBuffers()` then a **non-durable** `StateStore.save` (no fsync). On power loss, `downloadedBytes` (buffered offset) exceeds durably-written bytes; resume trusts the stale offset. | `http_transfer_job.dart:2153-2158` (verified: `flushBuffers()` + non-durable save + `catch{debugPrint}`) |
| H-1 | HIGH | Integrity re-hash is self-referential across a resume boundary: a resumed chunk's hash is computed over `[disk-prefix re-read + new bytes]` then "verified" by re-reading the same disk range — a tautology. | `http_transfer_job.dart:1304-1323` (hash build) vs `:1081-1086` (verify) |
| H-2 | HIGH | Preallocation (`raf.truncate(totalSize)`) makes on-disk length always == total, so **both** size-based completeness gates are no-ops. | `positional_file_writer.dart:101-103`; gates at `http_transfer_job.dart:821-825` and `download_orchestrator.dart:1560` |
| M-2 | MED | Double `_finalize()`: single-stream early-complete finalizes then `run()` finalizes again → temp file already renamed → `throw DownloadIntegrityException('Temporary download file missing')`. A complete download reported failed. | `http_transfer_job.dart:1553-1557` + `:493-494` → `:2007-2013` |
| M-3 | MED | Unknown-length single stream `break`s unconditionally and sets `totalSize = diskLen`, so a server closing the socket early looks identical to success. | `http_transfer_job.dart:1865-1874` |
| M-4 | MED | State-save failures swallowed to `debugPrint` — stale resume offset, no telemetry, no user error. | `http_transfer_job.dart:2159-2160`; `download_journal.dart:643-645` |
| M-1 | MED | No redirect/SSRF guard on the download path (`RedirectGuard` exists but only wired to the browser). Transfer Dio uses `followRedirects:true`. | `http_transfer_job.dart:1188,1674`; `RedirectGuard` only in `browser_controller.dart` |
| M-5 | MED | `ProfessionalRetryInterceptor` bails on any request with a `Range` header — i.e. every chunk and every resume. Advertised transport retry never applies to the core transfer. | `retry_interceptor.dart:35-44` |
| L-1 | LOW | Dead code: `sendChunkBytes`/`TransferableTypedData` never called. | `http_transfer_job.dart:280-282` |
| L-2 | LOW | Hot-chunk split mutates `parent.end` while another worker streams it; wastes in-flight bytes. | `http_transfer_job.dart:942-944,1338-1340` |

## The core fix: a real durability contract (C-1, H-1, H-2)

Today "downloaded" means *bytes handed to the writer*, but resume correctness needs *bytes durably on disk*. Introduce an explicit **durable high-water mark** per chunk and never let resume trust anything above it.

### Task 1.1 — Track a per-chunk `flushedHighWater`
- In `TransferState`/`ChunkState` (`transfer_state.dart`), add `int flushedHighWater` (bytes durably fsync'd for this chunk), persisted alongside `downloaded`.
- In `PositionalFileWriter`, add `Future<void> fsyncData()` that flushes buffers **and** calls `RandomAccessFile.flush()`/native fsync on the data handle. Return the byte ranges that are now durable.

### Task 1.2 — fsync data before every state/journal save
- In `_throttledSaveAndReport` (`http_transfer_job.dart:2146-2165`): replace `await writer.flushBuffers()` with `await writer.fsyncData()`, then set each chunk's `flushedHighWater = downloaded` **only after** fsync returns, then `StateStore.save(...)`.
- This makes the ordering: *data durable → mark durable → record state*. A crash between steps leaves state pointing at or behind real data — never ahead.

### Task 1.3 — Resume from the durable mark, not the buffered offset
- In `loadAndReconcileState` / `_reconcileWithDisk` (`download_journal.dart:383-433`): clamp each chunk's resume offset to `min(downloaded, flushedHighWater)`. Because preallocation makes file length meaningless (H-2), reconcile against `flushedHighWater`, not `diskLen`.
- Re-download the small tail between `flushedHighWater` and the last buffered offset. This is a few MB at most and guarantees byte-correctness.

### Task 1.4 — Make the integrity hash meaningful across resume (H-1)
- Persist the incremental SHA-256 **state** at each `flushedHighWater` (or store a per-durable-range hash). On resume, seed the hasher from the persisted state instead of re-reading the disk prefix and trusting it.
- At finalize, the whole-file hash then covers durably-written bytes end-to-end, so a bad prefix is detectable.

### Task 1.5 — Real completeness verification independent of file length (H-2)
- Add a `bytesActuallyWritten` accumulator (sum of bytes the writer confirmed to each offset) and assert `bytesActuallyWritten == totalSize` at finalize.
- Fix the provider Completion Gate (`download_orchestrator.dart:1560`) to stop relying on `actualSize < fileSize` for multi-thread downloads (always false under preallocation); use the chunk-sum / `bytesActuallyWritten` instead, and keep the whole-file SHA-256 verify as the final guard.

## Correctness bug fixes

### Task 1.6 — Make `_finalize` idempotent (M-2)
- Guard `_finalize` on `st.status == complete` OR temp-already-renamed → return success instead of throwing. Remove the redundant second call in `run()` (`:493-494`) when a sub-path already finalized. Add a regression test that submits an already-complete resumed single-stream download.

### Task 1.7 — Don't treat premature stream-end as success (M-3)
- When Content-Length is unknown, only accept completion if the server signalled clean EOF (e.g. chunked terminator / graceful close) — not any `break`. If bytes stop without a completion signal, mark `failed`/`interrupted` and allow resume. See `http_transfer_job.dart:1865-1874`.

### Task 1.8 — Surface persistence failures (M-4)
- Replace the `catch{debugPrint}` in `_throttledSaveAndReport` (`:2159`) and `StateStore.save` (`download_journal.dart:643`) with: log via `CrashReportingService`/`DiagnosticService`, increment a failure counter, and after N consecutive failures set a `persistenceDegraded` flag on the task (surfaced in the UI). Retry with backoff.

## Resilience layers that are misleading (clean up)

### Task 1.9 — Make the retry interceptor range-aware or delete it (M-5)
- Either teach `ProfessionalRetryInterceptor` (`retry_interceptor.dart:35-44`) to retry idempotent ranged GETs (they are safe to retry — same bytes), or delete it and rely on the engine's manual retry loops. Shipping a retry layer that never fires on the core transfer is a false sense of resilience.

### Task 1.10 — Route downloads through `RedirectGuard` (M-1)
- Wrap the transfer + metadata-probe Dio so every redirect hop is validated (scheme allowlist, block private/link-local IPs) using the existing `RedirectGuard`. Matches the browser path and closes an SSRF vector.

### Task 1.11 — Remove dead code / fix hot-split (L-1, L-2)
- Delete `sendChunkBytes`/`TransferableTypedData` (`:280-282`).
- In hot-chunk split, snapshot `parent.end` and stop the parent worker cleanly at the split point rather than mutating a field another worker is mid-read on (`:942-944`).

## Acceptance criteria (9.5 bar)

- A fault-injection test that hard-kills the process (and simulates un-fsync'd buffer loss) at randomized points during a multi-thread download **always** resumes to a file whose SHA-256 matches the origin. Run 100× in CI.
- No single-stream unknown-length download can complete on a truncated response.
- Global/whole-file checksum mismatch always yields `failed`, never `completed`.
- A resumed complete download never reports `DownloadIntegrityException`.
- Persistence failures produce telemetry + a user-visible degraded state.

## Test plan

1. **Fault-injection harness** (new `test/engine/durability_fault_injection_test.dart`): wrap `PositionalFileWriter` with an injector that can "lose" un-fsync'd bytes on demand; assert byte-perfect resume.
2. Unit test for `flushedHighWater` clamp in reconcile.
3. Regression test for double-finalize (Task 1.6) and premature EOF (Task 1.7).
4. SSRF test: redirect to `169.254.169.254` / `127.0.0.1` is refused on the download path.
5. Verify existing `test/download_cycle_fixes_test.dart` and engine tests stay green.

## Effort / risk

- Tasks 1.1–1.5 are the substantial ones (touch `transfer_state`, `positional_file_writer`, `http_transfer_job`, `download_journal`) — ~3–5 days, **medium risk** (core path; gate behind the fault-injection harness).
- Tasks 1.6–1.11 are localized — ~1–2 days total, low risk.
