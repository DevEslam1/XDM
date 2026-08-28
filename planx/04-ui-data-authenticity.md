# Plan 04 — UI Data Authenticity (kill the fake data)

**Priority: P1** (directly addresses the owner's "data must be real, not fake" concern)
**Current score: 7.5/10 (card ≈9.5, details ≈6.5) → target 9.5+/10**

Good news: the **download card is essentially all-real** (filename, sizes, progress, speed, ETA, sparkline, protocol, seeds/peers/upload-speed all trace to live model/provider data), and there are **no `Random()`, TODO, mock, or demo arrays** anywhere in the card or details screen. The speed graph/sparkline is fed genuine 1 Hz samples capped at 60 — not synthetic.

All the fakeness is concentrated in the **torrent portions of the details screen**, and it's downstream of the Plan 02 stubs. Some of it can be fixed purely in the UI today (hide/label); the rest requires the native bridge.

## Verified findings (evidence)

| ID | Sev | Field | Verdict | Evidence |
|---|---|---|---|---|
| F1 | CRITICAL | **Tracker panel** (list, seeds, peers, health, status) | FAKE | `details_screen.dart:2332` builds a fresh empty `TrackerManager()` never populated; `setTrackers()` has zero callers; "Add Default Trackers" injects a hardcoded list with `seeds/peers=0`, health frozen 50%. `tracker_manager.dart:5-16,38` |
| F2 | HIGH | **Current Tracker / Next Announce** (card properties sheet) | FAKE | hardcoded `currentTracker:''`, `nextAnnounceSeconds:0` → always render `—`. `torrent_service_ffi.dart:483-484`; `download_card.dart:3566,3583` |
| F3 | HIGH | **Availability / Distributed Copies** (dashboard + sheet) | FAKE | `distributedCopies:0.0` hardcoded → always `0.00x`; also poisons the health indicator input. `libtorrent_native_impl.dart:127`; `torrent_stats_dashboard.dart:104`; `download_card.dart:3576` |
| F4 | MED | **Piece counts** ("X / Y pieces") | SYNTHETIC-as-exact | `numPieces=totalWanted/256KB`, `piecesDone=numPieces*progress`, plus a "synthetic boolean bitfield for UI compatibility". Shown as precise. `libtorrent_native_impl.dart:84-96`; `details_screen.dart:2464`; `download_card.dart:3559` |
| F5 | MED | **Per-file torrent progress** | ESTIMATED (honestly labeled) | `fileProgress:[]` → files stay `progressEstimated`, rendered with an "≈/ESTIMATED" badge. Mitigated but still not real. `libtorrent_native_impl.dart:123`; `torrent_files_panel.dart:348-383` |
| F6 | LOW | Dead widget `TorrentMetadataProgress` (peers/dht) never instantiated. | N/A | grep: 0 call sites |

**Honestly real (confirmed):** HTTP per-segment channel bars (distinct `ChunkState.ratio`), aggregate seeds/peers/rates/totals (straight from libtorrent), the entire MetadataPanel, and the DL/UL speed graph. The PeerPanel per-peer list is **honestly absent** (UI explicitly says the engine exposes no enumeration) — that's the correct pattern to replicate for the other stubs.

## Tasks

The principle: **a metric must trace to a live source, or be explicitly labeled estimated, or be hidden.** Never render a hardcoded/synthetic value as if it were measured.

### Task 4.1 — Tracker panel: real or hidden (F1)
- **With Plan 02 Track A (bridge):** feed `_trackerManager.setTrackers(...)` from the torrent's real trackers, and populate seeds/peers/status from real scrape data. Add the missing `setTrackers` call site in `details_screen.dart` init.
- **Without the bridge (Plan 02 Track B):** hide the TrackerPanel (gate on `trackersSupported`), or render a single honest state: "Tracker details unavailable on this engine build." Remove the "Add Default Trackers" fake-success path so users aren't told trackers were added when they weren't.

### Task 4.2 — Current Tracker / Next Announce: hide when unavailable (F2)
- In the card properties sheet (`download_card.dart:3566,3583`), don't render these rows when the value is the hardcoded placeholder. Extend the existing "No live data" path. When the bridge lands, populate `currentTracker`/`nextAnnounceSeconds` from real announce state (`torrent_service_ffi.dart:483-484`).

### Task 4.3 — Availability/Distributed Copies: drop until real (F3)
- Remove the "Availability 0.00x" cell (`torrent_stats_dashboard.dart:104`) and the sheet's "Distributed Copies" (`download_card.dart:3576`) while `distributedCopies` is hardcoded 0.
- **Fix the health indicator** (`torrent_health_indicator.dart:22-37`) to not use the dead availability input — base health only on real seeds/peers/rate so it isn't silently skewed.

### Task 4.4 — Piece counts: label estimated (F4)
- Where piece counts are synthetic, render "~X / Y pieces (estimated)" or suppress the exact count; don't present the derived bitfield as an exact piece map. Locations: `details_screen.dart:2464`, `download_card.dart:3559`, `torrent_stats_dashboard.dart:98`. When the bridge returns a real bitfield, drop the "estimated" qualifier.

### Task 4.5 — Per-file progress (F5)
- Keep the honest "ESTIMATED" badge until Plan 02 2A.4 lands real `getFileProgress`; then the badge auto-clears because `progressEstimated` becomes false. No UI change needed beyond verifying the badge disappears when real data flows.

### Task 4.6 — Remove dead widget (F6)
- Delete `TorrentMetadataProgress` if it stays uninstantiated, or wire it to real DHT/peer metadata once available.

### Task 4.7 — Add a UI-truthfulness guard test
- A widget/golden test that, with the torrent engine in "no-capability" mode, asserts none of the fabricated rows (tracker list, availability, exact piece counts, current-tracker) render. This prevents regressions where a future dev re-adds a placeholder.

## Acceptance criteria (9.5 bar)

- Every number on the details screen and card either traces to a live engine/model value, is explicitly labeled "estimated," or is hidden.
- No hardcoded `0`/`''`/`50%`/`0.00x` is presented as a measurement.
- With the native bridge (Plan 02), tracker/availability/pieces/per-file all show real data and the "estimated" labels disappear automatically.

## Dependencies

- F1/F2/F3/F4/F5 real-data versions depend on **Plan 02 Track A**. The hide/label versions are **independent** and shippable now (Plan 02 Track B). Do the hide/label pass first — it's the fastest way to eliminate "fake data."

## Effort / risk

- Hide/label pass (4.1B, 4.2, 4.3, 4.4): ~1–2 days, low risk, pure UI.
- Real-data wiring (4.1A, 4.5): rides on Plan 02; ~1 day of UI glue once the bridge exists.
