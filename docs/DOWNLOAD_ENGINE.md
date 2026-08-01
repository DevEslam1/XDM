# XDM Download Engine Architecture & Hardening

## Overview
The XDM Download Engine is a multi-threaded, resilient HTTP/HTTPS download pipeline with journal integrity, adaptive thread estimation, per-domain speed governance, and orphan file cleanup.

## Core Features
1. **Journal Integrity (CRC32 Checksum)**:
   - All progress events are written to append-only `.journal` files wrapped with bitwise CRC32 checksums: `{"d": payload, "c": crc32}`.
   - Upon recovery, corrupted lines are logged and skipped without corrupting valid chunk progress.

2. **Adaptive Thread Estimation**:
   - Uses lightweight `HEAD` requests checking `Accept-Ranges` and server response metrics before allocating concurrent HTTP thread ranges.

3. **Per-Domain Speed Limiting**:
   - `BandwidthGovernor` tracks throughput history per domain to balance token allocation without starving fast hosts.

4. **HTTP/3 (QUIC) Support**:
   - `ConnectionManager` detects `Alt-Svc` headers and negotiates HTTP/3 connections via `cronet_http` (Android) and `cupertino_http` (iOS).

5. **Orphan File Cleanup**:
   - `DownloadEngine.cleanupOrphanFiles` cleans `.dmxpart`, `.dmxstate`, `.journal`, `.audio`, `.merged.*`, and `.part*` files on download cancellation or failure.
