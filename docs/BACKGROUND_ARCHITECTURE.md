# DMX Background Architecture

This document defines the clear operational boundaries between Android Foreground Services (FGS) and WorkManager background execution in DMX.

```
┌────────────────────────────────────────────────────────┐
│             DMX Background Execution Model             │
└────────────────────────────────────────────────────────┘
          │
          ├─► [Active Transfers In-Flight]
          │   └─► Foreground Service (dataSync)
          │       ├─ Max execution window: 5h 55m (Android 15+ timeout guard)
          │       ├─ Periodic state flush to .dmxpart & journal fsync
          │       └─ Graceful checkpoint & transition to WorkManager on timeout
          │
          └─► [Idle / Scheduled / Retries / App Suspended]
              └─► WorkManager (BackgroundScheduler)
                  ├─ Periodic maintenance
                  ├─ Quiet hours / off-peak execution
                  └─ Auto-resume after network reconnection
```

## 1. Foreground Service (`dataSync`) Boundary
- **Purpose**: Low-latency, high-throughput network streaming for active HTTP and BitTorrent transfers.
- **Notification**: High-priority sticky notification showing live aggregate speed and progress.
- **Android 15+ Timeout Policy**:
  - `dataSync` FGS is limited by Android 15 to a cumulative 6-hour window.
  - At the 5 hour 55 minute safety mark, DMX triggers an atomic checkpoint:
    1. Pauses active torrent and HTTP engines.
    2. Flushes and fsyncs binary journal logs.
    3. Saves durable `StateStore` snapshots to `.dmxpart`.
    4. Transitions task status to `paused` with reason `PauseReason.scheduled`.
    5. Enqueues a one-time WorkManager job with network constraint to resume the session in the background.

## 2. WorkManager Execution Boundary
- **Purpose**: Deferred, non-continuous batch processing when the app is suspended, device is idle, or during quiet hours.
- **Constraints**: Enforces Wi-Fi only, charging only, and battery-not-low requirements.
