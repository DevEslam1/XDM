# Architecture & Resource Budget

This document specifies the core architecture, memory budgets, per-singleton capacity limits, and timer cadences across the XDM downloads engine and background services.

---

## 1. Resource Budget

### 1.1 Singleton In-Memory Limits & Memory Caps

| Component / Singleton | In-Memory Cap | Eviction Policy | Storage Format |
|---|---|---|---|
| **`MirrorHealthStore`** | 200 entries | Access-ordered LRU | Incremental key-value per URL (`mirror_health_url_<url>`) via `SharedPrefsBatcher` with 5-minute debounce interval |
| **`ServerProfileManager`** | 100 profiles | $O(\log n)$ score-indexed tree eviction (`lastAccess` + reliability bonus) | In-memory cache with 7-day TTL and memory pressure eviction |
| **`MirrorBenchmarkService`** | 50 benchmark results | Access-ordered LRU | 1-hour TTL in-memory cache |
| **`ServerIdentityCache`** | In-memory cache | 10-minute stale cleanup | Transient in-memory identity map |
| **`BandwidthGovernor`** | Per-domain map | Drops domain states idle > 10 min | Active only while $\ge 1$ consumer registered |
| **`HttpTransferJob` delay queue** | Max 16 cancellable delays | Coalesce to non-cancellable direct `Future.delayed` on overflow | Timed completers map |
| **`DmxBackdropFilter`** | Max 1 concurrent active filter | Fallback to solid container when limit exceeded or low-end device | Active count gated by `PowerMonitor.isLowEndDevice` & `BackgroundGate.shouldAnimate` |

---

## 2. Timer Cadence & Background Adaptation

Every periodic timer is registered with and adapted via `BackgroundGate.adaptInterval` and `PowerMonitor`:

| Subsystem / Timer | Foreground Cadence | Background Cadence (`PowerMonitor.screenOff` / Background) | Lifecycle Rule |
|---|---|---|---|
| **`HttpDownloadEngine._monitorTimer`** | 5 seconds | 30 seconds (adapted via `BackgroundGate.adaptInterval`) | Deduped via timer generation; only starts when $\ge 1$ active tracker exists |
| **`BandwidthGovernor._domainCleanupTimer`** | 5 minutes | 5 minutes | Starts only when first consumer registers; cancels when `_activeConsumers == 0` |
| **`MirrorHealthStore._flushTimer`** | 5 minutes | 5 minutes (skipped when screen off unless `durable: true`) | Flushes dirty records incrementally via `SharedPrefsBatcher` |
| **`BackgroundService._iosBgWatchdogTimer`** | 25 seconds | 25 seconds | Watchdog fire resets in-flight state without imposing 60s cooldown; 60s cooldown strictly on native failure |
| **`BackgroundService._wakeLockRenewalTimer`** | 15 minutes | 15 minutes | Auto-releases when zero downloads remain or on aggressive battery saver |
| **`TorrentDownloadHandler._listenForCompletion`** | 5–120s (adaptive by file count) | 90s–5m (adaptive by file count) | Releases `cachedAccurateFiles` and `lastStateLabel` immediately on `removeActiveTorrent` |

---

## 3. Power & Device Tier Constraints

1. **Low-End Devices (`PowerMonitor.isLowEndDevice`)**:
   - `BackdropFilter` and heavy blur shaders are disabled, falling back to static solid/semi-transparent surfaces.
   - Heavy animations are paused via `BackgroundGate.shouldAnimate`.
   - Download worker thread counts and probe ranges are capped.

2. **Battery Saver Mode (`PowerMonitor.batterySaverMode`)**:
   - `moderate`: Throttles background token refill and limits concurrent chunk probes.
   - `aggressive`: Releases wake locks, pauses background heavy operations, and reduces concurrency.

3. **Service Lifecycle & Memory Pressure**:
   - All stateful singleton services register with `ServiceRegistry` implementing `DisposableService` and/or `MemoryPressureListener`.
   - On memory pressure broadcast, caches are cleared immediately and pending changes are batched to storage.
