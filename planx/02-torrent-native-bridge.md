# Plan 02 — Torrent Native Bridge & Real Capabilities

**Priority: P0/P1** (single biggest gap vs 1DM+/ADM/FDM; ~12 UI-exposed features are stubs)
**Current score: 5.0/10 → target 9.5+/10**

## Root cause

The project rolled back to the pub package `libtorrent_flutter: 1.9.2` (`pubspec.yaml:57`). That binding lacks the native symbols the app was built against. The Dart impl now delegates the essentials to libtorrent (add, metadata, piece download, disk write, pause/resume, speed limits, file skip, encryption — **these genuinely work**) but returns stubs for everything else. The bridge even documents this:

> `libtorrent_native_impl.dart:38-39` — "Running on libtorrent_flutter 1.9.2 which lacks support for piece bitfields, file progress, trackers management, resume data, and peer inspection."

Runtime wiring confirmed: `ITorrentService` → `TorrentServiceImpl` (`di/injection.dart:105-106`) → `_native = LibtorrentNativeImpl()` (`torrent_service_ffi.dart:51`). `FakeTorrentNative` is test-only (`@visibleForTesting setNativeForTesting`, `:53-54`).

## Verified stubs (evidence) — features that render in the UI but do nothing

| ID | Sev | Stub | Evidence |
|---|---|---|---|
| C1 | CRITICAL | **Fast-resume dead** → full recheck every launch. `saveResumeData`→`null`, `loadResumeData`→`false`, and `resumeData` param is dropped in `addMagnet`/`addTorrentFile`. | `libtorrent_native_impl.dart:384-397` (verified), `:274-285` |
| C2 | CRITICAL | **Tracker management is an in-memory facade.** `getTrackers`→`[]`, `addTracker`/`removeTracker`/`announceNow`→no-op. `TrackerManager` mutates a throwaway `Map` per screen. | `libtorrent_native_impl.dart:460-481`; `details_screen.dart:2332`; `tracker_manager.dart` |
| C3 | CRITICAL | **Create Torrent is a stub** (`createTorrent`→`null`) **and the screen is unreachable** (no navigation to `CreateTorrentScreen`). | `libtorrent_native_impl.dart:503-513`; `create_torrent_screen.dart:144-163` |
| H1 | HIGH | **Per-file progress empty** → `getFileProgress`→`[]`; UI falls back to file-existence "ESTIMATED" guesses. | `libtorrent_native_impl.dart:370-373`; `torrent_service_ffi.dart:1344-1354` |
| H2 | HIGH | **Sequential/streaming + super-seeding are no-ops** (`setSequentialDownload`, `setSuperSeeding`, `setPieceDeadline`). | `libtorrent_native_impl.dart:485-499` |
| H3 | HIGH | **SOCKS5 proxy for torrents is a stub** — a privacy claim that silently fails. (`forceEncrypt` DOES work.) | `libtorrent_native_impl.dart:524-532` |
| H4 | HIGH | **IP filter / blocklist is a stub** (`loadIpFilter`→`false`); blocklist download then no-op. | `libtorrent_native_impl.dart:517-520`; `torrent_service_ffi.dart:1263-1274` |
| H5 | HIGH | **Web seeds are a stub** (`addWebSeed`/`getWebSeeds`→no-op/`[]`). | `libtorrent_native_impl.dart:546-561` |
| H6 | HIGH | **Piece bitfield synthetic, info-hash empty.** Bitfield generated from overall %; `infoHashV1/V2:''`. | `libtorrent_native_impl.dart:84-96,126-127` |
| M2 | MED | "Adaptive tuning" layer (`TorrentSessionConfig`, `TorrentDiskManager`, `TorrentResourceManager`, `TorrentTrackerOptimizer`) is **dead code** — no call sites. | grep: 0 external callers |
| M3 | MED | `getFilePriorities` returns a Dart cache, empty after restart (though `setFilePriorities` **does** reach the engine). | `libtorrent_native_impl.dart:363-366` |
| L1 | LOW | Version drift: `nativeVersion => '2.1.1'` while pin is 1.9.2. | `torrent_service_ffi.dart:1705-1707` |

## Strategy: two tracks

The correct long-term fix (Track A) restores a capable native bridge. Because that's a bigger lift, Track B is a same-sprint "stop lying" fallback that hides/labels what can't work on 1.9.2, so the app is **honest** immediately even if full capability lands later. **Do Track B first (days), then Track A (weeks).**

---

## Track A — Restore a capable native bridge (the real fix)

### Task 2A.1 — Choose the bridge source
- Either (a) re-vendor a `libtorrent_flutter` build that exports the ABI-2 symbols (`save_resume_data`, `load_resume_data`, `file_progress`, `torrent_trackers`/`add_tracker`/`remove_tracker`/`force_reannounce`, `get_peers`, `set_sequential_download`, `set_piece_deadline`, `create_torrent`, `set_ip_filter`, `set_proxy`, `add_web_seed`, `info_hash`, `piece_bitfield`), **guaranteeing the Dart bindings and the prebuilt `.so`/`.dylib`/`.dll` ship from the same release** (the struct-layout drift that caused the rollback is the thing to avoid — pin bindings+binary to one tagged build); or (b) upgrade to a newer published `libtorrent_flutter` that exposes them.
- Add an ELF/Mach-O/PE symbol-validation step in CI (the repo already had a symbol-validation tool per git history) so a binary missing a symbol fails the build instead of silently stubbing at runtime.

### Task 2A.2 — Fast-resume (C1) — highest impact
- Implement `saveResumeData`/`loadResumeData` against the native calls.
- **Actually pass `resumeData`** into `addMagnet`/`addTorrentFile` (`libtorrent_native_impl.dart:274-285`) — today it's accepted and dropped.
- Flip `resumeDataSupported => true` (`torrent_service_ffi.dart:103`); the periodic resume-save loop (`:63-73`) and `TorrentResumeStore` (already crash-safe: tmp→fsync→rename, SHA-256, 16MB cap) then start receiving real blobs.
- Result: no full recheck on every launch; no re-download when partial files are intact.

### Task 2A.3 — Trackers (C2)
- Implement `getTrackers`/`addTracker`/`removeTracker`/`announceNow` against native.
- Feed `TrackerManager` from the torrent's **real** trackers (add a `setTrackers(...)` call site — today it has none) and populate seeds/peers/status from real scrape data.
- Flip `trackersSupported`/`reannounceSupported` true. This makes "add tracker to rescue a stalled magnet" actually work.

### Task 2A.4 — Per-file progress & priorities (H1, M3)
- Implement `getFileProgress` (real per-file bytes) and make `getFilePriorities` read native state (not the Dart cache).
- Removes the "≈/ESTIMATED" guesswork in `torrent_files_panel.dart`. Flip `fileProgressSupported`/`filePrioritiesSupported` true.

### Task 2A.5 — Sequential download / streaming & piece deadlines (H2)
- Implement `setSequentialDownload`/`setPieceDeadline` so `autoEnableSequentialForVideo` (`torrent_service_ffi.dart:1479-1495`) actually orders pieces for streaming — a core media-DM differentiator. Implement `setSuperSeeding`. Flip the flags.

### Task 2A.6 — Privacy features: proxy + IP filter (H3, H4)
- Implement `setProxy` (SOCKS5/HTTP) and `loadIpFilter`. These are **trust-critical** — today the UI implies torrent traffic is proxied/filtered when it isn't. Flip `ipFilterSupported`.

### Task 2A.7 — Web seeds + create torrent + info-hash/pieces (H5, C3, H6)
- Implement `addWebSeed`/`removeWebSeed`/`getWebSeeds`.
- Implement `createTorrent` and **wire a navigation entry** to `CreateTorrentScreen` (currently orphaned). Fix the faked success check (`create_torrent_screen.dart:163`).
- Return real `infoHashV1/V2` and a real piece bitfield; flip `createTorrentSupported`.

### Task 2A.8 — Activate the dead tuning layer (M2)
- Once the bridge is capable, wire `TorrentSessionConfig.buildOptimizedConfig` / disk-IO mode / cache size / per-torrent connection & concurrency limits into session setup (see Plan 05 for the settings→session bridge). Or delete it if not adopting.

### Task 2A.9 — Fix diagnostics (L1)
- Make `nativeVersion` report the actual pinned build; keep `bridgeDiagnostics` accurate.

---

## Track B — Honest degrade now (ship this first, ~2–3 days)

The capability flags already exist and are already `false` (`torrent_service_ffi.dart:101-112`) — they're just **not consumed by the UI**. Make the UI gate on them.

### Task 2B.1 — Gate panels on capability flags
- `TrackerPanel`, web-seed UI, IP-filter/anonymous-mode settings, sequential/super-seeding toggles, and the Create-Torrent entry: render only when the corresponding `*Supported` flag is true; otherwise hide or show a clear "Not supported by current engine build" note.

### Task 2B.2 — Stop displaying fabricated metrics
- `currentTracker`/`nextAnnounceSeconds`/`distributedCopies` are hardcoded (`torrent_service_ffi.dart:483-484`; `libtorrent_native_impl.dart:127`). Hide these rows when unavailable (the card already has a "No live data" path — extend it). See Plan 04.
- Label piece counts "~X (estimated)" while they're synthetic (H6). See Plan 04.

### Task 2B.3 — Remove the fake "Add Default Trackers" success path
- Don't let the tracker panel imply trackers were added to the swarm when `addTracker` is a no-op.

### Task 2B.4 — Move `fake_torrent_native.dart` under `test/`
- It's test-only but lives in the production `lib/` tree — hygiene + avoids confusion.

## Acceptance criteria (9.5 bar)

- Restarting the app on a partially-downloaded torrent resumes **without a full recheck** and without re-downloading intact data.
- Every torrent panel shows real engine data, or is hidden on builds that can't provide it — **nothing fabricated**.
- Adding a tracker to a stalled magnet measurably changes peer discovery.
- Sequential mode lets a video start playing before completion.
- Proxy/IP-filter, when shown, actually route/filter traffic (verify with a packet capture / known blocklisted IP).
- Create Torrent produces a valid `.torrent` that other clients accept, and its screen is reachable.

## Test plan

1. Resume test: download 30%, kill, relaunch → state is `downloading` from ~30% with no `checkingResume` full pass.
2. Tracker test: add a working public tracker to a magnet with 0 peers → peer count rises.
3. Per-file progress test: multi-file torrent → per-file bytes advance monotonically and sum to overall.
4. Proxy test: set SOCKS5 to a local proxy → all peer traffic egresses via the proxy.
5. Create test: create from a folder → open the `.torrent` in Transmission/qBittorrent successfully.
6. Capability-gate test (Track B): with all flags false, no fabricated panels render.

## Effort / risk

- **Track B: ~2–3 days, low risk** — UI gating + hiding placeholders. Ship immediately for honesty.
- **Track A: ~2–4 weeks, medium/high risk** — depends on sourcing a symbol-complete native binary and avoiding the struct-drift that caused the rollback. Land it symbol-by-symbol behind CI symbol validation; fast-resume (2A.2) and trackers (2A.3) first for the biggest UX wins.
