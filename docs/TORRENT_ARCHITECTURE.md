# DMX BitTorrent Architecture

This document describes the design, native FFI layer, lifecycle state machine, and persistence strategy of the BitTorrent subsystem in DMX.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Torrent Session Lifecycle                    │
└─────────────────────────────────────────────────────────────────┘
                              │
     ┌────────────────────────┴────────────────────────┐
     ▼                                                 ▼
[Magnet URL]                                     [.torrent File]
     │                                                 │
     ▼                                                 ▼
[fetchingMetadata] ───► [allocating] ───► [verifying] ───► [downloading]
                              ▲                                   │
                              │ (Fast-Resume Data)                ▼
                              └────────────────────────────── [completed]
                                                                  │
                                                                  ▼
                                                              [seeding]
```

## 1. Core Abstractions & FFI Interface
- **`ITorrentService`**: Unifying interface contract separating platform-specific implementations.
- **`TorrentService` (FFI)**: Direct C/C++ FFI binding communicating with `libtorrent-rasterbar`.
- **`TorrentSessionManager` / `TorrentSessionService`**: Manages torrent state caches, seeding policies, and file priorities.

## 2. Fast-Resume & Per-File Durability
- Fast-resume data is persisted to `.fastresume` blobs using `TorrentResumeStore`.
- Per-file progress and priority maps are persisted to SQLite so individual file downloads survive app restarts without requiring full SHA-1 hash re-checks.

## 3. Ratio Enforcement & Power Awareness
- `SeedingPolicy` limits uploads by maximum ratio (default 2.0), max duration, and network type (e.g. Wi-Fi only, while charging only).
