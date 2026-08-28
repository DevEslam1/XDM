# Plan 07 — Resource Management (RAM / CPU / GPU / IO / Background) + Control Center

**Priority: P1** (correctness-adjacent: bad resource behavior = jank, OOM kills, battery drain, thermal throttling — all things that make users uninstall a DM)
**Current maturity (audited 2026-08-24): RAM 7 / CPU 8 / GPU 5 / IO 6 / Background 8 → target 9.5+ across the board**

Unlike the torrent/settings areas, DMX already has a **genuinely strong resource-management spine** — this plan is mostly about (a) fixing a few dead/debug-only pieces, (b) making device adaptation less crude, and (c) exposing it all through one honest **Performance & Resources** control center instead of the current 6-toggle power page (2 of whose toggles do nothing).

## What already works (confirmed — don't rebuild these)

- **`PowerMonitor`** (`power_monitor.dart`) is real and sophisticated: native thermal polling (`MethodChannel com.dmx.app/thermal`), battery-saver hysteresis (`batterySaverMode`, anti-flapping), `maxAllowedThreads` (1/2/16 by thermal+battery), a master `throttleFactor` scalar (0.3–1.0), adaptive poll intervals, and Android `requestIgnoreBatteryOptimizations`.
- **`BackgroundGate`** (`background_gate.dart`) is a real central throttle: `allowHeavyOps`/`allowLightOps`/`allowAnyWork` + `scaleInterval` (screen-off ×30, background ×10, aggressive-saver ×15, moderate ×5). Every timer/animation is supposed to route through it.
- **Isolate-pool auto-scaling** (`download_isolate_pool.dart:125-135` `effectiveMaxSize`): screen-off or low-end → 1 worker; aggressive/severe-thermal → low; moderate → reduced; else base (4).
- **Memory-pressure system** (`main.dart:84-90` `didHaveMemoryPressure` → `ServiceRegistry.broadcastMemoryPressure()`): real, with many `MemoryPressureListener`s (`connection_manager`, `mirror_registry`, `positional_file_writer:400`, `site_intelligence`). Clears image cache + live images.
- **Adaptive image cache** (`main.dart:127-132`): `maximumSizeBytes`/`maximumSize` scale by device memory tier.
- **`SystemMonitorsCard`** (`system_monitors_card.dart`): real live readout of battery/charging/thermal/throttleFactor/saver + jank%/build-ms/raster-ms, with adaptive 2s/4s refresh that stops when screen-off.

## Verified findings (evidence)

| ID | Dim | Sev | Finding | Evidence |
|---|---|---|---|---|
| R1 | GPU/CPU | HIGH | **Frame monitoring + jank auto-degradation are debug-only.** `PerformanceMonitor.start()`, `FrameWatchdog.start()`, and the `jankAutoBatterySaver` → `setBatterySaverMode(true)` handler are all inside `if (kDebugMode)`. In **release builds they never run**, so the "Auto Battery Saver on Jank" setting is effectively dead in production. | `main.dart:135-159` |
| R2 | RAM | MED | **Device-memory detection is a crude binary.** `_getDeviceMemoryGB` returns `2.0` only for Android `isLowRamDevice`, else `4.0`; iOS always `4.0`; desktop falls through to `4.0`. High-RAM (8–16GB) devices get the same 50MB/100-entry cache as a 4GB phone; desktops are under-provisioned. | `main.dart:93-109,128-132` |
| R3 | CPU | MED | **`powerAwareIsolatePool` toggle is FAKE-DEAD.** The pool always scales via `PowerMonitor` regardless of the setting; toggling it off does **not** disable scaling. No consumer reads `settings.powerAwareIsolatePool`. | `power_settings_page.dart:93`; `download_isolate_pool.dart:125` (unconditional) |
| R4 | IO | MED | **`diskWriteBatching` toggle is FAKE-DEAD & mislabeled.** Subtitle claims "256KB batching," but there's no consumer; the writer already buffers unconditionally (8MB pending / 4MB flush threshold). | `power_settings_page.dart:131`; `positional_file_writer.dart:64,331` |
| R5 | IO/CPU | MED | **`TorrentDiskManager` & `TorrentResourceManager` are dead code** (0 call sites). Torrent disk cache size, IO mode, piece size, per-torrent connection/concurrency limits, and screen-off download limit are never applied. | grep: no callers outside their own files |
| R6 | RAM | LOW | **`isLowEndDevice` uses CPU cores only**, not RAM (`Platform.numberOfProcessors <= 2`). An 8-core/3GB device is treated as high-end for memory purposes. | `power_monitor.dart:68-76` |
| R7 | GPU | LOW | **No shader warmup / no release-mode GPU lite auto-switch.** Visual gating (`reduceVisuals`/`enableGlow`/`gridOpacity`/`classicUi`) is manual-only; nothing auto-drops effects on a janky low-end device in release (because R1). | `main.dart` (no `PaintingBinding` shader warmup) |
| R8 | Monitor | LOW | **No real RAM/CPU% readout.** The "Live System Monitors" card shows battery/thermal/jank/frame-times but **not process memory (RSS) or CPU load** — the two numbers users most associate with "resource usage." | `system_monitors_card.dart:121-131` |
| R9 | Background | LOW | **No "download only while charging" / background data cap** beyond `wifiOnly`. Battery-optimization exemption prompt exists (`requestIgnoreBatteryOptimizations`) but isn't clearly surfaced in settings. | `power_monitor.dart:301`; settings pages |

## Tasks

### Task 7.1 — Make frame monitoring + auto-degradation work in release (R1) — highest leverage
- Move `PerformanceMonitor`/`FrameWatchdog` init out of the `kDebugMode` block so they run in release **at low overhead** (sample, don't log every frame). Gate verbose logging on debug, not the monitoring itself.
- Wire the `jankAutoBatterySaver` handler in release so 3 consecutive janky windows actually trigger a graceful degrade. **Degrade GPU first, not battery-saver wholesale:** step down = disable blur/glow → reduce animations → then, only if still janky, reduce concurrency. (Today it jumps straight to full battery-saver, which also throttles downloads — too blunt.)
- This turns R7 into a real feature: automatic GPU-lite on struggling devices.

### Task 7.2 — Real device-tier detection + auto profile (R2, R6)
- Replace `_getDeviceMemoryGB` with real total-RAM detection (Android `ActivityManager.MemoryInfo.totalMem` via a MethodChannel; iOS `os_proc_available_memory`/`ProcessInfo.physicalMemory`; desktop via `sysinfo`). Fall back to the current heuristic on failure.
- Fold RAM **and** cores into a single **DeviceTier** (`low` / `balanced` / `high`) computed once at startup. Base `isLowEndDevice`, image-cache size, isolate cap, and default visual settings on the tier — not just core count.
- Scale image cache continuously: e.g. `cacheMB = (totalRamGB * 8).clamp(30, 256)`, `maxEntries` similarly. Desktops with 16GB should cache far more than a 3GB phone.

### Task 7.3 — Fix or remove the dead resource toggles (R3, R4)
- **`powerAwareIsolatePool`:** either make the pool scaling **conditional** on this setting (so users can pin a fixed pool size), or remove the toggle. If kept, it must actually gate `effectiveMaxSize` behavior.
- **`diskWriteBatching`:** either wire it to the writer's buffer thresholds (`positional_file_writer.dart:64,331` — e.g. toggle between aggressive 8MB batching and a low-latency 256KB mode), or remove the toggle and its misleading subtitle.
- Rule (same as Plan 05): no toggle that reads back a value nothing consumes.

### Task 7.4 — Activate or delete the torrent resource/disk managers (R5)
- If keeping torrents competitive (Plan 02), wire `TorrentDiskManager.optimalPieceSize/optimalDiskIoMode/optimalCacheSizeMb` and `TorrentResourceManager.maxConcurrentTorrents/maxConnectionsPerTorrent/screenOffDownloadLimit` into session setup + the queue — driven by DeviceTier (7.2) and the `diskCacheSizeMb` setting (currently FAKE-DEAD per Plan 05). This depends on the capable native bridge for disk-IO/cache config (Plan 02 Track A).
- If deferring torrents, **delete** these classes to stop implying tuning that never happens.

### Task 7.5 — Real RAM/CPU in the live monitor (R8)
- Add process RSS (Android `Debug.getPss`/`Runtime` or `/proc/self/statm`; iOS `task_info`/`os_proc_available_memory`; desktop `ProcessInfo`) and CPU load to `PerformanceMonitor`, sampled on the same adaptive 2s/4s cadence, and show them in `SystemMonitorsCard`. Keep it honest — if a platform can't provide a metric, hide it (don't fabricate, per the Plan 04 principle).

### Task 7.6 — Background execution controls (R9)
- Add "Download only while charging" and "Pause background downloads on cellular" (extend the existing `wifiOnly`/`BackgroundGate` machinery — the charging/wifi state is already in `PowerMonitor`/`networkMonitor`).
- Surface the Android battery-optimization exemption (`requestIgnoreBatteryOptimizations`) as a clear one-tap action with an explainer, since without it long background downloads get killed.
- Verify the Android foreground-service + iOS BGTask model and expose a "keep alive in background" explainer where relevant.

### Task 7.7 — The unified "Performance & Resources" control center (the settings page you asked for)
Replace the current 6-toggle `PowerSettingsPage` with a single scrollable control center. Structure:

```
┌ Performance & Resources ─────────────────────────────┐
│ [ Live System Monitors ]  (existing card + RAM/CPU)   │  ← 7.5
│                                                        │
│ PERFORMANCE PROFILE                                    │
│  ( ) Battery Saver   (•) Balanced   ( ) High Performance   ← preset that sets the sliders below
│  [Auto] adapt to device tier + thermal (recommended)   │  ← 7.2 DeviceTier
│                                                        │
│ CPU                                                    │
│  Max download threads .......... [ 8 ]  (1–16)         │  ← caps maxAllowedThreads / effectiveMaxSize
│  Isolate worker pool ........... [Auto ▾]              │  ← 7.3 (pin vs power-aware)
│  Thermal thread limiter ........ [on]                  │  ← existing (EFFECTIVE)
│                                                        │
│ MEMORY                                                 │
│  Image cache ................... [ 80 MB ] (30–256)    │  ← 7.2 wire to PaintingBinding.imageCache
│  Clear caches now .............. [button]              │  ← calls broadcastMemoryPressure()
│                                                        │
│ GPU / VISUALS                                          │
│  Visual quality ................ [Full / Lite / Off]   │  ← maps reduceVisuals/enableGlow/gridOpacity
│  Auto-reduce effects on jank ... [on]                  │  ← 7.1 (now works in release)
│                                                        │
│ DISK / IO                                              │
│  Write buffering ............... [Balanced ▾]          │  ← 7.3 real diskWriteBatching
│  Torrent disk cache ............ [ 64 MB ]             │  ← 7.4 (or hidden if torrents deferred)
│                                                        │
│ BATTERY / BACKGROUND                                   │
│  Power bandwidth throttling .... [on]                  │  ← existing (EFFECTIVE)
│  Download only while charging .. [off]                 │  ← 7.6
│  Pause background on cellular .. [off]                 │  ← 7.6
│  Ignore battery optimizations .. [Grant]  (Android)    │  ← 7.6
└────────────────────────────────────────────────────────┘
```

Implementation notes:
- The **Performance Profile** presets (Battery Saver / Balanced / High Performance) are just bundles that set the individual controls; "Auto" defers to `DeviceTier` + `PowerMonitor`. This gives one-tap simplicity **and** granular control.
- Every control must map to a real consumer (`PowerMonitor.maxAllowedThreads`, `effectiveMaxSize`, `PaintingBinding.imageCache`, the visual-gating flags, the writer thresholds). No new dead toggles.
- Keep it reactive (no restart): the app already reacts to `PowerMonitor` notifiers and `SettingsProvider` via `Consumer` — route new caps through the same notifiers.

### Task 7.8 — "No dead resource toggle" guard test
- Extend the Plan 05 Task 5.8 enumeration test to cover the new controls: every control on this page must have ≥1 read site that changes behavior.

## Acceptance criteria (9.5 bar)

- On a low-RAM device, image cache + isolate cap + visuals auto-scale down; on a 16GB desktop they scale up (measurable via the monitor).
- Sustained jank in a **release** build automatically drops visual effects (verified by forcing jank).
- The live monitor shows real RSS + CPU (or honestly hides them on unsupported platforms).
- Every control on the Performance & Resources page has a real, verifiable effect; zero dead toggles (guard test passes).
- Long background downloads survive on Android (battery-optimization exemption granted) and respect charging/cellular gates.
- No OOM kill in a stress test (many large concurrent downloads on a 2–3GB device).

## Test plan

1. DeviceTier test: mock 2GB / 4GB / 16GB → assert cache size, isolate cap, default visuals differ (7.2).
2. Release jank test: inject slow frames → assert visual-quality auto-steps-down (not full battery-saver) (7.1).
3. Toggle-effect tests: max-threads cap actually caps `effectiveMaxSize`; image-cache slider changes `PaintingBinding.imageCache.maximumSizeBytes`; "download only while charging" pauses on unplug (7.3/7.6/7.7).
4. Monitor test: RSS/CPU values are non-zero and update on the adaptive cadence (7.5).
5. OOM stress test on a memory-constrained emulator.
6. Guard test: no dead resource toggle (7.8).

## Dependencies & sequencing

- 7.1, 7.2, 7.3, 7.5, 7.7 are **independent** of the other plans — do them in Phase 2/3.
- 7.4 (torrent disk/resource tuning) depends on **Plan 02 Track A** (native bridge for disk-IO/cache config); until then, hide those controls.
- The image-cache/thread caps should be coordinated with **Plan 01/03** durability work (they touch the writer buffers and isolate pool).

## Effort / risk

- 7.1: ~1–2 days, **medium risk** (release-path frame monitoring — validate overhead is negligible).
- 7.2: ~2 days (needs small native MethodChannels for total RAM), low/medium risk.
- 7.3/7.6/7.8: ~1 day total, low risk.
- 7.5: ~1–2 days (native RSS/CPU channels), low/medium risk.
- 7.7 (the control-center UI): ~2–3 days, low risk (mostly UI wiring to existing consumers).
- 7.4: rides on Plan 02.
