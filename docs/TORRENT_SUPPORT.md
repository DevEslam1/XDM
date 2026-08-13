# XDM Torrent Architecture & Features

## Overview
XDM integrates `libtorrent_flutter` (FFI with stub fallbacks) for P2P torrent and magnet link downloads, background lifecycle management, tracker governance, ratio enforcement, torrent creation, and advanced connection/disk tuning.

## Key Subsystems
1. **DHT Bootstrap & Metadata Resolution**:
   - Injects static DHT bootstrap nodes (`router.bittorrent.com:6881`, `dht.transmissionbt.com:6881`, etc.) upon session initialization.
   - `addMagnetWithMetadataTimeout` resolves metadata with 5s status notifications, auto-retrying with extra default trackers (`maxRetries = 2`, `retryDelay = 10s`) before failing.

2. **Tracker Governance & Health**:
   - `TrackerManager` provides 10 default open UDP trackers (`defaultTrackers`), calculates `trackerHealthScore`, auto-adds default trackers when torrents have `< 3` trackers, and supports `autoReannounceFailing`.
   - Real-time `TrackerPanel` UI displaying tracker health scores and tier priority controls.

3. **Torrent Queue & Smart Seeding Rules**:
   - `SettingsProvider` defines `maxActiveTorrents`, `maxActiveDownloads`, `maxActiveSeeds`, `seedOnlyWhenCharging`, and `seedOnlyOnWifi`.
   - `DownloadTorrentMixin` enforces concurrency queues and `SeedingPolicy` checks ratio limits (`shareRatioLimit`) and max seeding durations.

4. **Dual Speed History & Health Evaluation**:
   - Real-time dual download & upload speed history charting in the transfer speed graph.
   - `calculateHealth` categorizes torrent health into 5 levels (`Dead`, `Poor`, `Fair`, `Good`, `Excellent`) using seeds, peers, availability, distributed copies, and download rate.

5. **Peer Quality & Encryption**:
   - `PeerPanel` UI displays peer connection quality percentages, encryption lock icons, connection direction (incoming/outgoing), flags, and relevance scores.

6. **Sequential Download & Super Seeding**:
   - Dynamic capability-gated calls for `enableSequentialDownload`, `setPieceDeadline` (video streaming preview), and `enableSuperSeeding`.

7. **Disk-Verified Per-File Progress**:
   - `getAccurateFileProgress` probes actual file bytes on disk, detecting pre-allocated zero-fill files before reporting true completion percentage.

8. **Torrent Creation & Customization**:
   - `CreateTorrentScreen` UI supports piece size selection (Auto, 256KB to 8MB), Web Seeds URL input, source tags, comments, and private torrent toggles.

9. **Privacy & Blocklist Filtering**:
   - `loadBlocklist` and `downloadAndApplyBlocklist` support loading HTTP/P2P blocklists to filter malicious peers.

