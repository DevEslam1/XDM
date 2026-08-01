# XDM Torrent Architecture & Features

## Overview
XDM integrates `libtorrent_flutter` for P2P torrent and magnet link downloads, background lifecycle management, tracker governance, ratio enforcement, and torrent creation.

## Key Subsystems
1. **Tracker Management**:
   - `TorrentService.getTrackers`, `addTracker`, `removeTracker`, and `announceNow` allow full real-time tracker inspection and tier priority tuning.

2. **Torrent Queue Management**:
   - `SettingsProvider` defines `maxActiveTorrents`, `maxActiveDownloads`, and `maxActiveSeeds`.
   - `DownloadTorrentMixin.enforceTorrentQueue()` automatically pauses excess active downloads or seeds.

3. **Ratio Auto-Stop Enforcement**:
   - `checkTorrentRatioLimits()` continuously monitors share ratio (`totalPayloadUpload / totalPayloadDownload`) and seeding time against `shareRatioLimit` and `maxSeedingTimeMinutes`.

4. **Peer Discovery Protocols**:
   - Supports DHT, UPnP, NAT-PMP, LPD, and PEX peer discovery.

5. **Torrent Creation**:
   - `CreateTorrentScreen` UI and `TorrentService.createTorrent` generate standard Bencoded `.torrent` metadata files.

6. **IP Filter Blocklist**:
   - Supports loading `.dat` IP filter blocklists (`loadIpFilter`).
