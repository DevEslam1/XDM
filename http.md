# DMX HTTP Download Engine — Status & Remaining Work

> Re-verified against current source 2026-09-20. The production loop bug and the two
> real single-stream correctness bugs are **already implemented** in the working tree
> (uncommitted). This doc records what's done (so it isn't re-done or reverted) and what
> genuinely remains.
>
> Primary file: `lib/core/services/engine/http_transfer_job.dart` (~3090 lines).
> Supporting: `transfer_state.dart`, `download_journal.dart`, `positional_file_writer.dart`,
> `bandwidth_governor.dart`, `download_isolate_pool.dart`, `mirror/mirror_selector.dart`.

---

## Rating vs IDM / 1DM: ~9/10

Strong, in places ahead of both — worker-isolate pool, positional writer, WAL journal,
per-chunk SHA integrity, SSRF-revalidated redirects, de-raced mirror failover with
identity re-probing, disk-truth resume clamps. Remaining gaps are the global speed budget
(not work-conserving) and two feature items (whole-file checksum, multi-source). No known
correctness blocker after the fixes below.

---

## ✅ DONE — verified in current source (do NOT revert or re-do)

### The "1.2 MB → File system error → restart from zero" loop — FIXED
Two root causes, both now handled:

- **A1 — non-ENOSPC `FileSystemException` on single-stream write no longer aborts the job.**
  `http_transfer_job.dart`: a `rafFaulted` flag (`:2048`), a write-site catch
  (`:2268-2269`), and an attempt-level `on FileSystemException` catch (`:2427-2465`) that
  maps disk-full as fatal but otherwise **resumes from `tempFile.length()` and retries in
  place** (never zeroes). The `finally` (`:2466-2479`) is guarded by `rafFaulted` so a
  broken handle can't double-throw and mask the real error.
- **A2 — empty-chunks snapshot no longer misclassified as corrupt.** `tryParseV3`
  (`transfer_state.dart:174-187`) now returns a valid zero-progress state when `chunks`
  is empty (only `rawChunks.isNotEmpty && chunks.isEmpty` is treated as corrupt). The
  loader (`download_journal.dart:182-201`) has a matching guard that builds a
  zero-progress state instead of the warning + `.bak` + restart path. Resume proceeds
  from disk length instead of looping.

### Other single-stream correctness — FIXED
- **B2 — single-stream no longer silently adopts a 206's Content-Length as `totalSize`.**
  `http_transfer_job.dart:2220-2244`: `totalSize` is only *set* when unknown (`<= 0`); a
  known-size mismatch restarts only if server identity actually changed, else just logs.
- **B3 — 416 in single-stream no longer loops on unknown size.**
  `:2068-2092`: parses Content-Range total to establish size, and if disk length already
  covers it, completes instead of restarting.

---

## ✅ DONE — global speed cap (verified 2026-09-20)

### R1 — Work-conserving global speed budget — ALREADY IMPLEMENTED
`download_isolate_pool.dart:616-675` `_rebalanceBandwidth` is the shared budget: a single
active job receives 100% of the global limit (`:631-638`); with multiple jobs, any job
measured below 75% of its fair share is granted `measured × 1.25` and its surplus is
redistributed to demanding jobs (`:640-663`). Grants are pushed per-job with `active: 1`,
so the worker's `_effectiveGlobalLimit` (`http_transfer_job.dart:2641`) uses the grant
directly. Fed by real progress samples (`_recordJobSpeed`, `:832`) and driven from the UI
(`download_provider.dart:287` → `DownloadEngine.updateSpeedLimit` → pool). The earlier
"fake global speed limit" audit note is stale.

---

## ⏳ REMAINING

### R2 — Single-chunk / unhashed-chunk integrity — NOT worth a content scan *(closed)*
`_runIntegrityPipeline` returns early for `chunks.length <= 1` (`:1293`) and skips
`hash == null` (`:1308`). A *content* hole-scan is the wrong fix: it's O(filesize) and
false-positives on files that legitimately contain zero runs. The existing guards already
cover this correctly — final size check (`:2493`), multi-thread `sum/diskLen >= total`
(`:966-975`), F17 disk-truth clamp, and J4 pre-flight all prevent a chunk from claiming
bytes it never wrote. **No action; recording a hash with no reference to compare against
adds no safety.**

### R3 — `PositionalFileWriter` handles opened `FileMode.append` *(INVESTIGATE — do NOT naively "fix")*
`positional_file_writer.dart:166,208` use `FileMode.append`; the sibling
`MappedFileWriter` (`:673-674`) uses `FileMode.writeOnly` with a comment implying the
append→writeOnly change should apply here too.
**⚠️ Correction to earlier guidance: do NOT change these to `FileMode.writeOnly`.**
`FileMode.writeOnly` **truncates the file to zero on open**, which would destroy
pre-allocated / resumed data every time a pooled handle is created. On standard `dart:io`,
`FileMode.append` does *not* use POSIX `O_APPEND` — it seeks to EOF on open, and the
subsequent `setPosition(pos)` (`:309`) before each `writeFrom` writes at the correct
offset on all platforms. So `append` is functionally correct today.
**If a device test on Android/Windows ever shows out-of-order segment writes landing at
EOF, the correct replacement is `FileMode.writeOnlyAppend`** (write-only, no truncate) —
never `writeOnly`. Until such a test fails, leave it as-is. Add the two-non-adjacent-
segment integration test to lock the behavior down.

---

## 🎯 Features vs IDM / 1DM

1. **Whole-file checksum** — ✅ DONE. User-supplied `expectedSha256` and the
   `autoVerifyChecksum` setting are both verified in the orchestrator completion gate
   (`download_orchestrator.dart:1638-1786`). **Added 2026-09-20:** the engine now also
   auto-captures a server-advertised digest (`Digest` / `Repr-Digest` / `Content-Digest`,
   RFC 3230/9530) and verifies the finished file against it in `_finalize`
   (`http_transfer_job.dart`, `_captureServerDigest` + finalize check) — costs nothing
   unless the origin actually sends the header. `flutter analyze` + checksum tests green.
2. **Cross-download scheduler / queue priority** — ⚠️ PARTIAL. Priority-ordered dispatch
   already exists (`download_isolate_pool.dart:340-355,444-454`: highest priority, then
   FIFO by seq). **Not done:** "smallest-remaining-first" ordering and end-game mode.
   These change user-visible queue order, so gate behind a setting and validate on device.
3. **Per-connection adaptive chunk sizing by measured RTT** — ⏳ NOT done. Splitting is
   midpoint-of-remaining (`http_download_engine.dart:36-40`); buffer size adapts at
   >60 MB/s but initial segment sizing is not RTT-tuned. Medium effort; touches the
   working splitter — needs before/after throughput measurement to justify.
4. **Simultaneous multi-source download** — ⏳ NOT done. `MirrorFailover` only fails over
   sequentially. Pulling different chunks from different mirrors at once (aria2/1DM style)
   is a large worker-pool change; per-chunk identity re-probe (`_advanceChunkMirror`) and
   integrity already exist to guard it, but it needs real multi-mirror device testing
   before shipping — do not blind-merge into the working engine.

---

## Already-correct — DON'T "fix" (verified)

Concurrency is `clamp(1,16)` + learned host cap (not 4). Mirror `advance(failedUrl)` is
de-raced (`mirror_selector.dart:479-491`). Mid-chunk mirror switch re-validates identity
(`_advanceChunkMirror`). Identity probe cancels immediately on a range-ignoring 200.
Goodput uses a per-chunk stopwatch. 206 without Content-Range is accepted. Stream/client
disposal and multi-stream resume durability (F17 disk-truth clamp, high-water clamp, J4
pre-flight) are all handled.

---

## Acceptance / verification

For any remaining change: cite `file:line`, add/adjust a test under `test/`, run
`flutter analyze` + the relevant `flutter test`, keep v2/v3 state serialization
backward-compatible. Regression tests worth adding for the DONE fixes: (a) `tryParseV3`
on an empty-chunks doc returns a zero-progress state; (b) a single-stream write
`FileSystemException` (non-ENOSPC) triggers in-place retry from disk length.
