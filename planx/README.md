# DMX → 9.5+ Roadmap

Goal: take DMX from a genuinely-built, above-average download manager to a **best-in-class competitor to 1DM+, ADM, and FDM** (target 9.5+/10 across engine, data integrity, UI truthfulness, settings, features, and resource management).

This folder is the output of a full, evidence-based audit of the codebase (branch `main`, v3.0.0+1). Every claim in these plans is backed by a `file:line` reference verified against source — **not** against the stale write-ups in `docs/` (those are historical intent, not current state).

## Current scorecard (audited 2026-08-24)

| Area | Score | One-line reality |
|---|---|---|
| HTTP download engine | 7.5/10 | Real segmentation, positional writes, WAL resume, dual-layer checksums, real speed. Loses points on a **power-loss corruption window** and a couple of defeated safety gates. |
| Torrent engine | 5.0/10 | Genuinely downloads/seeds/pauses via libtorrent 1.9.2, but ~12 UI-exposed features are **stubs or fabricated** (fast-resume, trackers, create, per-file progress, sequential, proxy, web seeds, IP filter). |
| State persistence / data loss | 7.0/10 | Solid WAL + atomic-rename + fsync + startup replay. Gaps: unknown-size finalize window, dual-writer dead code, screen-off journaling blackout, no DB downgrade path. |
| UI data authenticity | 7.5/10 | Download card ≈9.5 (all real). Details screen ≈6.5, dragged down by **fake torrent tracker/availability/pieces** data. |
| Settings effectiveness | 5.5/10 | ~58% of settings actually work. **Global speed limit is fake**; nearly the entire torrent "Session & Protocols" panel is decorative. |
| Feature / UX breadth | 8.0/10 | Exceeds mobile competitors on browser/ad-block/user-scripts/torrent-create. **Media extraction is 100% dependent on one remote Cloud Run backend** (single point of failure); categories are hardcoded; no HTTP auth/proxy. |
| Resource management (RAM/CPU/GPU/IO/bg) | 6.8/10 | Strong `PowerMonitor`/`BackgroundGate`/memory-pressure spine. But **frame monitoring + jank auto-degrade are debug-only (dead in release)**, device-tier detection is a crude 2/4GB binary, and 2 power-page toggles do nothing. |

**Weighted overall: ~6.8/10.** The app is real and ambitious; the gap to 9.5 is concentrated in (1) correctness/durability, (2) torrent native capability, (3) honesty of settings & torrent UI.

## The three themes behind almost every finding

1. **Durability discipline** — periodic saves flush OS buffers but don't `fsync`, and file preallocation defeats size-based completeness checks. A hard power loss can mark a corrupted file "complete."
2. **The libtorrent 1.9.2 rollback stripped native symbols** — everything that depends on `save_resume_data`, `file_progress`, tracker management, `create_torrent`, `set_proxy`, web seeds, and IP filter is now a stub returning `null`/`false`/`[]`. The UI still renders those panels, so features *look* functional while doing nothing.
3. **Wiring gaps between UI and engine** — several settings/toggles persist a value that no code ever reads (global speed limit, torrent session flags, HTTPS-only, save-history). The plumbing to consume them often already exists; it's just not connected.

## How the plans are organized & sequenced

Work is grouped into seven plan files, ordered by leverage. Do them roughly in the phase order below.

| # | Plan | Fixes | Why this priority |
|---|---|---|---|
| [01](01-http-engine-durability.md) | HTTP engine durability & correctness | C-1 power-loss corruption, H-1/H-2 defeated gates, finalize double-call, unknown-length, retry/redirect gaps | **P0** — silent data corruption is the worst class of bug for a download manager. |
| [02](02-torrent-native-bridge.md) | Torrent native bridge & real capabilities | fast-resume, trackers, per-file progress, sequential, create, proxy, web seeds, IP filter | **P0/P1** — restores ~12 features that are stubs today; single biggest gap vs competitors. |
| [03](03-data-integrity-persistence.md) | Persistence & data-loss elimination | unknown-size finalize gap, dual-writer, screen-off blackout, DB downgrade, cross-isolate locks | **P0/P1** — prevents re-downloads and inconsistent state. |
| [04](04-ui-data-authenticity.md) | UI truthfulness | tracker panel, current-tracker/next-announce placeholders, synthetic piece counts, always-zero availability | **P1** — kills the "fake data" the owner specifically flagged. Depends partly on 02. |
| [05](05-settings-effectiveness.md) | Make settings real | global speed limit, torrent session wiring, HTTPS-only, save-history, remove/implement dead toggles | **P1** — restores user trust; several are one-liners. |
| [06](06-feature-parity-ux.md) | Feature parity & UX polish | de-risk media extraction, HTTP auth/headers, HTTP proxy, custom categories, link grabber, localization, speed scheduler | **P2** — reaches feature parity + differentiation. |
| [07](07-resource-management.md) | Resource management + control center | release-mode jank auto-degrade, real device-tier detection, dead power toggles, RAM/CPU monitor, background gates, unified Performance & Resources page | **P1** — prevents jank/OOM/battery drain (uninstall triggers); adds the all-in-one control page. |

## Definition of "9.5+" per area (acceptance bar)

- **Engine:** no code path can mark an incomplete/corrupt file "complete"; verified by a fault-injection test (kill/power-loss mid-write) that always resumes to a byte-perfect file.
- **Torrent:** every panel shown in the UI is backed by real engine data, or is hidden when the binding can't provide it. Fast-resume works (no full recheck on restart).
- **Data:** killing the app at any point loses at most a few seconds of progress and never the whole download; no inconsistent DB/file state survives a restart.
- **UI:** zero displayed metrics are hardcoded/synthetic; every number traces to a live source or is explicitly labeled/omitted.
- **Settings:** 100% of shipped settings have a real consumer that changes behavior (or are removed).
- **Features:** parity on table-stakes (HTTP auth, proxy, custom categories) + no single-point-of-failure for a headline feature.
- **Resources:** image cache / isolate cap / visuals auto-scale by real device tier; sustained jank in a **release** build auto-drops effects; the live monitor shows real RSS/CPU; every control on the Performance & Resources page has a verifiable effect (zero dead toggles).

## Suggested execution phases

- **Phase 1 (correctness, ~1–2 wks):** Plan 01 in full + Plan 03 H1/M2. Ship the fault-injection test harness first so fixes are provable.
- **Phase 2 (torrent truth, ~2–4 wks):** Plan 02 native bridge (or the "honest degrade" fallback in 02 §7 if the native rebuild is deferred) + Plan 04 + Plan 05 torrent-session wiring.
- **Phase 3 (settings + parity, ~2–3 wks):** Rest of Plan 05 + Plan 06 high-leverage items (media-extraction de-risk, HTTP auth/proxy, custom categories) + Plan 07 device-independent items (7.1 release jank auto-degrade, 7.2 device tier, 7.3 dead toggles, 7.5 RAM/CPU monitor, 7.7 the Performance & Resources control center).
- **Phase 4 (polish):** remaining Plan 06 + localization + accessibility coverage + Plan 07 items that ride on other plans (7.4 torrent disk/resource tuning depends on Plan 02's native bridge; 7.6 background gates coordinate with Plan 05's speed-limit wiring).

Each plan file ends with **acceptance criteria** and a **test plan** so "done" is unambiguous.
