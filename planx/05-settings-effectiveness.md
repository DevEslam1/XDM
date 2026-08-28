# Plan 05 — Make Settings Real

**Priority: P1** (restores user trust; several fixes are one-liners with plumbing already present)
**Current score: 5.5/10 (~58% of settings work) → target 9.5+/10 (100% real or removed)**

Of ~82 user-facing settings: ~48 EFFECTIVE, ~5 STUBBED-CONSUMER, ~29 FAKE-DEAD. The working ones are mostly UI/notification/browser conveniences; the **most-expected control (global speed limit) and nearly the entire torrent "Session & Protocols" panel are non-functional.** Crucially, for the two highest-impact fixes the consuming plumbing **already exists** — it's just not connected.

## Verified findings (evidence)

### CRITICAL

**S1 — Global speed limit slider is fake.** Verified end-to-end:
- `download_provider.dart:1378` → `int effectiveSpeedLimit() => 0;` (hardcoded)
- `http_download_orchestrator.dart:199` → `initialSpeedLimit: 0` (hardcoded)
- `download_engine.dart:525-528` → `updateSpeedLimit(...)` exists and delegates to `_pool.updateSpeedLimit` (`download_isolate_pool.dart:572`) → workers (`http_transfer_job.dart:2079`) — **but has no production caller** (only tests).
- The token-bucket governor (`bandwidth_governor.dart`) is real but only ever receives a *per-task* limit, never the global one.
- **The fix is wiring, not new machinery.**

**S2 — Torrent Session/Protocol toggles never reach the session.** DHT, UPnP, force-encrypt, global connection limit, sequential (STUBBED-CONSUMER: mapped but fed defaults) + NAT-PMP, LPD, PEX, uTP, LSD, per-torrent peers (FAKE-DEAD).
- `reconfigureSession()` → `_configureSessionFromSettings()` → `configureSession(const TorrentSessionSettings())` **with defaults, ignoring user values** (`torrent_service_ffi.dart:325,349`).
- The bridge `toTorrentSessionSettings()` (`settings_provider.dart:1525`) and `torrentSettingsPack` (`:344`) have **zero callers**; `TorrentSessionConfig.build*` are dead.

### HIGH
- **S3 — HTTPS-only is decorative** (`httpsOnly`): no consumer; insecure requests not blocked. `network_settings_page.dart:176` (display only).
- **S4 — Save browser history does nothing** (`saveBrowserHistory`): history inserted unconditionally (`browser_history_repository.dart:152`). A privacy control that silently fails.
- **S5 — Bandwidth schedule (enable/start/end/scheduled-speed)** feeds `effectiveSpeedLimitBytesPerSecond`, whose only consumers are the dead torrent config builders. Never applied. (Fixed for free once S1 is wired.)
- **S6 — Global torrent seeding master switch** (`globalTorrentSeeding`): unused; only sub-limits are read, so seeding can't be turned off here.

### MEDIUM / LOW (FAKE-DEAD toggles)
`categoryFolders`, `maxActiveTorrents`, `diskCacheSizeMb`, `enableIpFilter`/`ipFilterPath`, `enableAnonymousMode`, `useLocalYtFallback`, `formAutofill`, `openLinksInApp`, `pinchToZoom`, `translateTargetLang`, `developerMode` (explicitly neutered), `cleanupDays`, `maxConcurrentFilesPerTorrent`, `powerAwareIsolatePool`, `diskWriteBatching`, NAT-PMP/LPD/LSD, `maxPeerConnectionsPerTorrent`.

### Code hygiene
- `download/network/power/ui` settings mixins are **exported but never mixed in** (`settings_provider.dart:24` mixes only `TorrentSettingsMixin`) → dead duplicates (e.g. `keepPartsAfterFailedMerge` unreachable).
- `TorrentSessionConfig.buildBtConfigFromPack/buildOptimizedConfig/settingsToPack` — entirely dead.

## Tasks (highest ROI first)

### Task 5.1 — Wire the global speed limit (S1) — biggest single win, ~half a day
- Make `DownloadProvider.effectiveSpeedLimit()` (`download_provider.dart:1378`) return `settings.effectiveSpeedLimitBytesPerSecond` (this getter already folds in the bandwidth schedule, so **S5 is fixed for free**).
- Set `initialSpeedLimit` in `http_download_orchestrator.dart:199` from that value.
- Call `engine.updateSpeedLimit(bps, activeCount)` whenever `speedLimitMb` **or** the active-download count changes (the broadcast-to-workers path already exists at `download_isolate_pool.dart:572`). Recompute per-task share = `global / activeCount`.
- Verify against `bandwidth_governor` global bucket so a 1 MB/s cap actually holds across N concurrent downloads.

### Task 5.2 — Feed real settings into the torrent session (S2)
- Change `_configureSessionFromSettings()` (`torrent_service_ffi.dart:349`) to call `configureSession(SettingsProvider.instance.toTorrentSessionSettings())` instead of `const TorrentSessionSettings()`.
- Trigger `reconfigureSession()` from the torrent settings-page setters (on change) so toggles apply live where libtorrent supports runtime reconfig, or on next session start otherwise (with a "applies on restart" note).
- Extend `NativeBtConfig`/`configureSession` mapping to cover uTP/LSD/PEX/NAT-PMP/LPD/maxPeer/cache. **Note:** several of these ultimately require the capable native bridge (Plan 02); until then, gate them (Plan 02 Track B) rather than showing dead toggles.

### Task 5.3 — Honor HTTPS-only (S3)
- Add an HTTPS-enforcement check keyed on `httpsOnly` in the request/redirect path (combine with the `RedirectGuard` wiring from Plan 01 Task 1.10): refuse or upgrade `http://` requests when enabled.

### Task 5.4 — Honor Save-history (S4)
- Gate `browser_history_repository` inserts (`:152`) on `saveBrowserHistory`. Trivial and a real privacy expectation.

### Task 5.5 — Fix Global torrent seeding master switch (S6)
- Make `globalTorrentSeeding=false` actually stop/prevent seeding in `torrent_seeding_manager`/`download_torrent_mixin` (today only the sub-limits are honored). `seedingEnabled` is hardcoded true in `torrent_service_ffi.dart:1468` — drive it from the setting.

### Task 5.6 — Decide: implement or delete every remaining dead toggle
For each FAKE-DEAD setting, pick one:
- **Implement** if it's expected table-stakes: `categoryFolders` (→ Plan 06 custom categories), `diskCacheSizeMb`/`enableIpFilter`/`anonymousMode` (→ Plan 02 bridge), `maxActiveTorrents` (wire into the torrent queue).
- **Delete the UI** if it's not worth building now: `pinchToZoom`, `translateTargetLang`, `openLinksInApp`, `formAutofill`, `useLocalYtFallback`, `developerMode`, `powerAwareIsolatePool`, `diskWriteBatching`, `cleanupDays`, `maxConcurrentFilesPerTorrent`.
- **Rule:** shipping a toggle that does nothing is worse than omitting it. No setting should persist a value nothing reads.

### Task 5.7 — Delete abandoned config layer & dead mixins
- Remove `TorrentSessionConfig.build*` and the four never-mixed settings mixins to end the "which path is live?" confusion. (Keep whatever Task 5.2 actually adopts.)

### Task 5.8 — Add a "no dead settings" guard test
- A test that enumerates every persisted settings key and asserts each has ≥1 read site outside the provider (a simple static/grep-based allowlist test). Fails CI if someone adds a write-only setting.

## Acceptance criteria (9.5 bar)

- Setting a 2 MB/s global cap holds across multiple concurrent downloads (measured).
- Toggling a torrent session flag changes libtorrent behavior (or the toggle is hidden on unsupported builds — no decorative toggles).
- HTTPS-only blocks/upgrades insecure requests; Save-history off means no rows written.
- 100% of shipped settings have a real consumer (verified by Task 5.8's test), or are removed.

## Test plan

1. Global speed-limit integration test: 2 downloads, 1 MB/s cap → combined throughput ≤ ~1 MB/s (Task 5.1).
2. Torrent session test: set `forceEncrypt`/`connectionsLimit` from settings → assert `configureSession` receives user values, not defaults (Task 5.2).
3. HTTPS-only + save-history unit tests (5.3, 5.4).
4. "No dead settings" enumeration test (5.8) — also serves as the acceptance gate.

## Dependencies

- 5.1, 5.3, 5.4, 5.5 are **independent** and shippable now (biggest trust wins).
- 5.2 partially depends on Plan 02 (some flags need the native bridge); wire the settings→session bridge now, gate the unsupported flags via Plan 02 Track B.

## Effort / risk

- 5.1: ~0.5 day, low risk, huge perceived value. **Do this first.**
- 5.3/5.4/5.5: ~0.5 day each, low risk.
- 5.2: ~1–2 days, medium risk (session lifecycle).
- 5.6/5.7/5.8: ~1–2 days, low risk (mostly deletion + a test).
