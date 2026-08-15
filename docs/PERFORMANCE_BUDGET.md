# DMX Performance Budget

This document defines the strict performance budgets, system resource allocations, and architectural constraints enforced across the DMX codebase.

---

## 1. Frame & UI Rendering Budget

* **Frame Budget:** 16.6 ms per frame (target 60 FPS minimum on standard devices; 120 FPS on ProMotion/high-refresh screens).
* **Jank Allowance:** 0 jank frames on low-end devices (`PowerMonitor.isLowEndDevice`).
* **BackdropFilter Gating:**
  * Background blurs (`BackdropFilter`) are dynamically gated behind `BackgroundGate.shouldAnimate && !PowerMonitor.isLowEndDevice && !DmxBackdropFilter.disabled`.
  * Heavy visual animations are repainted only inside `RepaintBoundary` nodes to prevent dirtying parent widget subtrees.
* **Continuous Jank Mitigation:**
  * `PerformanceMonitor` tracks frame render times over 60-frame sliding windows.
  * If the jank ratio exceeds 5%, `onSustainedJank` fires and automatically disables expensive blur filters and reduces UI motion.

---

## 2. Memory Budget

* **Peak RSS Budget:** < 120 MB RSS during 8-thread concurrent multi-part downloads.
* **Buffer Allocation:**
  * Fixed chunk ring buffers with bounded memory ceilings.
  * Native socket buffers recycled via Object Pools.
* **Graph & State Sampling:**
  * Speed graph history capped at 60 samples (1 minute @ 1 Hz) to prevent unbounded memory retention during long download sessions.
* **Memory Pressure Strategy:**
  * When OS memory warning triggers (`ServiceRegistry.broadcastMemoryPressure()`), `DioClientPool` and isolate worker pools release all idle clients and halve reserved buffers.

---

## 3. Database & I/O Write Budget

* **Persistence Rate:** Maximum 1 flush per 5 seconds (batched/coalesced).
* **Periodic Debouncing:**
  * History entries and task updates are queued in-memory and flushed in single global batches via `_historyFlushTimer` (5s interval) and `saveTaskDebounced`.
  * Individual rapid writes do not hit disk immediately unless `immediate: true` is explicitly requested.
* **Storage Maintenance:**
  * Background database maintenance performs `PRAGMA wal_checkpoint(TRUNCATE)`, `PRAGMA optimize`, `PRAGMA incremental_vacuum(50)`, and `PRAGMA foreign_key_check`.

---

## 4. Network & Worker Isolate Budget

* **Battery Mode:** Maximum 4 active isolates (or 1 isolate under `BatterySaverMode.aggressive`).
* **AC / Charging Mode:** Maximum 8 active isolates with adaptive scaling.
* **Crash Resilience:**
  * Microtask queue is drained prior to isolate worker respawn to eliminate stale in-flight messages.
  * Transient failures re-queue up to 3 times before terminal error delivery.

---

## 5. Background CPU Budget

* **Idle Background Budget:** 0.0% CPU when screen is off and the download queue is empty.
* **Screen-Off Operation:**
  * Non-critical periodic timers (speed graphing, UI metrics, FFmpeg log polling) are suspended.
  * StateStore flushes switch from 100 KB delta thresholds to 5 MB thresholds or shutdown/pause checkpoints.
