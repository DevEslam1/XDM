# XDM — Complete Feature Reference, Wiring Map & Gap Analysis

> Purpose: this is the single reference of **every feature in XDM**, what **functions** implement it,
> how it is **wired** to the app and UI, what the **ideal/best-practice behavior** is, and the
> **current status / gaps / bugs**. Use it to compare the shipped app against the intended behavior
> and to drive fixes.
>
> Generated from a static, full-codebase audit (386 Dart files). Every entry cites `file:line`.
> Status tags: **[C]** confirmed from code/absence of callers · **[S]** suspected · **[D]** dead/unreachable · **[T]** test-only.

## How to read an entry

Each feature is documented as:

```
### F-x Feature name
- Where
- Functions
- Wiring
- Ideal
- Status / gaps / bugs
```

## Severity legend

`S1` blocker/crash · `S2` functional defect · `S3` dead/unwired feature · `S4` cleanup/consistency

## Subsystem index

- [Part A — HTTP Download Engine](#part-a--http-download-engine)
- [Part B — BitTorrent / P2P](#part-b--bittorrent--p2p)
- [Part C — Downloads Orchestration & State](#part-c--downloads-orchestration--state)
- [Part D — In-App Browser](#part-d--in-app-browser)
- [Part E — Add Download, YouTube & Cloud](#part-e--add-download-youtube--cloud)
- [Part F — Settings & Resources](#part-f--settings--resources)
- [Part G — Subscription](#part-g--subscription)
- [Part H — Onboarding, Permissions & App Lock](#part-h--onboarding-permissions--app-lock)
- [Part I — UI, Theme, Navigation & Accessibility](#part-i--ui-theme-navigation--accessibility)
- [Part J — Platform Services (notifications, background, widgets, remote, updates)](#part-j--platform-services)
- [Part K — Categories & History](#part-k--categories--history)
- [Part L — Prioritized Bug / Gap Backlog](#part-l--prioritized-bug--gap-backlog)

---

# Part A — HTTP Download Engine

Architecture (one line):
`DownloadProvider → DownloadOrchestrator → IDownloadEngine.download → DownloadEngine → (HTTP) HttpDownloadOrchestrator → DownloadIsolatePool → worker isolate → HttpTransferJob` →
progress returns via `PoolJob.messages → DownloadProgressHandler → onProgress → provider/UI`.

### F-A1 `IDownloadEngine` port & `DownloadRequest`
- **Where:** `lib/core/interfaces/i_download_engine.dart`, `lib/core/domain/download_request.dart`
- **Functions:** `downloadRequest(DownloadRequest)` `:8`; long-form `download({...})` `:10`; `resolveMetadata(...)` `:42`; `close()` `:52`; `forceCancelJob(String)` `:54`; `hasEnoughDiskSpace(String,int)` `:56`; `buildTempFilePath` `:58`; `updateSpeedLimit(int,int)` `:60`.
- **Wiring:** implemented only by `DownloadEngine` (`download_engine.dart:37`); DI `injection.dart:120`; held by `DownloadProvider` (`download_provider.dart:58-64,150,223`); called from `download_orchestrator.dart:2567,2792,3141`.
- **Ideal:** one canonical request object carrying every parameter the engine accepts.
- **Gaps:** `DownloadRequest` lacks `authUsername/authPassword/customHeaders` even though `download()` accepts them → `downloadRequest()` cannot carry HTTP auth/custom headers. **[C] S4**. `copyWith` uses `??` so nullable fields cannot be cleared. **[S] S4**.

### F-A2 Domain engine types
- **Where:** `lib/core/domain/engine_types.dart`
- **Functions:** `DownloadMetadata` `:20` (`isValid`, `copyWith`); `ChunkDetail` `:68`; `DownloadProgress` `:143` (`fromWorkerMap`, `progress`, `progressRatio`, `ytCombinedProgress`, equality `:349`); `DownloadError` `:381`.
- **Wiring:** produced by `DownloadProgressHandler.handleWorkerProgress` (`download_progress_handler.dart:505`); consumed by provider/widgets. `DownloadMetadata` from `MetadataProbeService`.
- **Ideal:** progress snapshot with stable value equality for rebuild gating; complete field toggle support.
- **Gaps:** `copyWith` cannot null fields (`eta`, `pauseReason`). **[S] S4**. Deprecated `chunks` list always emitted null (`http_transfer_job.dart:2781`) — dead field. **[C] S4**.

### F-A3 `CycleState` + `CycleStateResolver`
- **Where:** `lib/core/domain/cycle_state.dart`, `lib/core/services/engine/cycle_state_resolver.dart`
- **Functions:** `fromLibtorrent(String?)` `:52`; `fromName` `:122`; resolver `resolve({statusMessage,isCancelled,isTorrent})` `:31` (compiled regex + `BoundedLruCache`).
- **Wiring:** `DownloadProgressHandler.deriveCycleState` `:194`; `HttpTransferJob._deriveCycleState` `:2801`.
- **Ideal:** single canonical mapping of native/worker status strings to UI states.
- **Gaps:** bare `"updating"` without link/url/mirror/expire falls through to `starting`. **[S] S4**.

### F-A4 `DownloadEngine`
- **Where:** `lib/core/services/download_engine.dart`
- **Functions:** `markForeground/Background` `:48/:51`; `buildTempFilePath` (`.dmxpart`) `:128`; `hasEnoughDiskSpace` (iOS probe/`df -k`/PowerShell) `:134`; `estimateOptimalThreads` `:250`; `cleanupOrphanFiles` `:302`; `sweepStaleTempFiles` `:359`; `resolveMetadata` `:422`; `download` `:474` (torrent branch `:519`, else HTTP `:540`); `updateSpeedLimit` `:571`; `dispose/close` `:581/:594`.
- **Wiring:** constructed in DI `injection.dart:120-132`; injected into `DownloadProvider`; torrent routed to `TorrentDownloadHandler`.
- **Ideal:** route to HTTP/torrent, enforce permission + disk, manage isolate pool, expose cancellation/limits.
- **Gaps/bugs:**
  - `_torrentOrchestrator` injected `:68/:118` but **never called** → `TorrentDownloadOrchestrator` alert handling never runs. **[C] S3**
  - `_activeDownloadsCount` is never updated (`setActiveDownloadsCount` has no callers) → `hasActiveDownloads` is **always false**; breaks `TickManager` (`tick_manager.dart:104,113`), `BackgroundGate.adaptInterval` (`:15`), and ambient/glow gating. **[C] S2 — cross-cutting**
  - `estimateOptimalThreads`, `sweepStaleTempFiles`, `validateSavePath` production-unused. **[C] S3**
  - `_diskCheckCache` is an unbounded static `Map`. **[S] S4**

### F-A5 `DownloadIsolatePool` + worker IPC
- **Where:** `lib/core/services/download_isolate_pool.dart`, `lib/core/services/engine/http_transfer_job.dart`
- **Functions:** `EngineMessage` `:3`; `PoolMetrics` `:45`; pool `init` `:156`, `submit` `:340`, `forceCancelJob` `:518`, `updateSpeedLimit` `:596`, `shutdown` `:603`, `drain` `:658`; `PoolJob` `:742`; `workerEntry` `:58`.
- **Wiring:** pool created lazily by `DownloadEngine._ensurePool` `:400`; jobs submitted by `HttpDownloadOrchestrator.download` `:248`.
- **Ideal:** bounded isolate pool, power/foreground aware, priority queue, crash requeue.
- **Gaps:** unreachable `_shuttingDown` re-check `:345-349` (already thrown at `:341`). **[C] S3**. `PoolChunkResult` `:726` dead. **[C] S3**.

### F-A6 `HttpTransferJob` (worker, 2891 lines)
- **Where:** `lib/core/services/engine/http_transfer_job.dart`
- **Functions:** `requestCancel` `:283`; `sendUnhandledError` `:328`; watchdogs `:378/:424`; `computeHardTimeoutForSize` `:594`; `loadAndReconcileState` `:436`; `executeDownload` `:524`; `_runMultiThreaded` `:860`; `_executeAdaptiveScheduling` `:1055`; `_runIntegrityPipeline` `:1258`; `_runChunk` `:1337`; `spotCheckResumedBytes` `:1707`; `_runSingleStream` `:1778`; `_finalize` `:2321`; `_emitProgress` `:2666`; static `validateContentRange` `:2817`, `handle416` `:2871`.
- **Wiring:** instantiated in `workerEntry` `:71`; errors consumed by `HttpDownloadOrchestrator` `:330-353`.
- **Ideal:** 16-way segmented download, CRC32 journal recovery, checksum verification, mirror failover, adaptive scheduling, atomic finalize.
- **Gaps:** `_resetToSingleStream` sends a `telemetry` message type not in `EngineMessageType`/`_onWorkerMessage` → nonfunctional (harmless). **[C] S4**. `probeSupportsRange` computed but unused `:1091`. **[S] S4**. `_isExpiredUrlOrSite(bodyText)` `:2609` never given a body. **[S] S4**.

### F-A7 `DownloadJournal` + `StateStore`
- **Where:** `lib/core/services/download_journal.dart`
- **Functions:** `StateStoreFactory` `:21`; `StateStoreInstance` (`loadOrCreate` `:118`, `save` `:496`, `resetTransferState` `:740`); `DownloadJournal` (`open` `:1018`, `flushAndSync` `:1038`, `writeInit` `:1067`, `recordChunkProgress` `:1092`, `writeCheckpoint` `:1148`, `recoverWithDetails` `:1187`, `crc32` `:1489`).
- **Wiring:** DI `injection.dart:66-68`; used by `HttpTransferJob._runChunk` `:1603`; recovery in `loadOrCreate` `:229-269`.
- **Ideal:** crash-proof append-only CRC32 journal; on restart recover finished byte ranges without redownload.
- **Gaps:** `writeInit` `:1067` and `writeCheckpoint` `:1148` have **no callers** → post-compaction recovery loses init/thread metadata. **[C] S2**. `stateSaveStrictDedup` `:68` never read. **[C] S3**.

### F-A8 `PositionalFileWriter` & integrity
- **Where:** `lib/core/services/positional_file_writer.dart`, `lib/core/services/checksum_service.dart`
- **Functions:** writer `open/openForResume/write/flush/flushPaced` `:117-405`; `ChecksumService.sha256File/sha1File/md5File/verify/parseDigestHeader` `:37-75`.
- **Wiring:** writer used by `HttpTransferJob._runMultiThreaded` `:876`; checksum used in `download_orchestrator.dart:1609,1638,1722`.
- **Ideal:** positional disk writes with ENOSPC mapping; checksum verification at completion.
- **Gaps:** `AsyncWritePipeline` `:565` and `MappedFileWriter` `:652` dead. **[C] S3**. `ChecksumService.parseDigestHeader` unused → `Digest`/`Content-Digest` response header never validated. **[C] S3**.

### F-A9 `BandwidthGovernor` / `BandwidthArbiter`
- **Where:** `lib/core/services/bandwidth_governor.dart`
- **Functions:** `onPowerStateChanged` `:44`; `throttleFactor` `:91`; `setGlobalLimit/updateLimit/setLimit` `:117-125`; `acquire/acquireBlocking/acquireNonBlocking` `:170-186`; domain speed `:270`; `BandwidthArbiter.arbitrate` `:309`.
- **Wiring:** per-job governors created in `HttpTransferJob` `:922/:1845`; DI singleton `injection.dart:179` (never resolved).
- **Ideal:** global token-bucket cap + per-domain quotas + power throttling.
- **Gaps:** `BandwidthArbiter` never instantiated; DI `BandwidthGovernor` unused; per-job governors are not coordinated with the singleton. **[C] S3**. Domain cleanup scheduled twice (raw timer + TickManager) `:55-70`. **[S] S4**.

### F-A10 Retry / CircuitBreaker / ConnectionManager / protocol cache
- **Where:** `retry_engine.dart`, `retry_interceptor.dart`, `circuit_breaker.dart`, `connection_manager.dart`, `protocol_cache.dart`, `protocol_fallback_memory.dart`, `engines/connection_warmer.dart`
- **Functions:** `RetryEngine.getDelayForAttempt/shouldRetry/execute` `:56-78`; `ProfessionalRetryInterceptor.onError` `:28`; `CircuitBreaker.allowRequest/guard` `:56/:96`; `ConnectionManager.prewarm/detectHttp2` `:43/:75`; `ProtocolCache.get/record/recordFailure` `:44-64`; `ConnectionWarmer.warmConnection/warmQueuedTasks` `:23/:66`.
- **Wiring:** `RetryEngine` used by `MirrorFailover.run`; interceptor added in `buildTransferDio`; `CircuitBreaker` used by `MirrorFailover`; `ProtocolFallbackMemory` used by `HttpTransferJob`.
- **Ideal:** exponential backoff, circuit breaking, HTTP/2/3 negotiation, connection pre-warming.
- **Gaps:** `CircuitBreakerRegistry`/`UrlCircuitBreaker` dead. **[C] S3**. `ConnectionManager` registered but never resolved. **[C] S3**. `ProtocolCache.init()` never called → `get()` always null. **[S] S2**. `ConnectionWarmer` registered but never consumed; `warmQueuedTasks` never called. **[C] S3**.

### F-A11 `DioClientPool` + `DioNetworkPolicy`
- **Where:** `lib/core/services/dio_client_pool.dart`
- **Functions:** `DioNetworkPolicy.update/httpProxyActive` `:21`; pool `acquireClient` `:211`, `_applyProxy` `:297`, `releaseClient` `:330`, `registerDownload/unregisterDownload` `:373/:377`.
- **Wiring:** DI singleton `injection.dart:88`; injected into metadata/orchestrators/engine; policy updated at startup `main.dart:184`.
- **Ideal:** bounded client pool with HTTPS-only + proxy enforcement, safe eviction of busy clients.
- **Gaps:** `releaseClient` removes from `_activeClients` but not `_reservedClients`. **[S] S4**. `registerDownload`/`unregisterDownload` have no callers → eviction can release an in-flight client. **[C] S2**.

### F-A12 `MetadataProbeService`
- **Where:** `lib/core/services/metadata_probe_service.dart`
- **Functions:** `resolveMetadata` `:45`; `_probeWithHead` `:145`; `_probeWithGet` `:205`; `_resolveTorrentMetadata` `:281`.
- **Wiring:** DI `injection.dart:94`; used by `HttpDownloadOrchestrator` `:73/:116` and `DownloadEngine.resolveMetadata` `:431`.
- **Ideal:** HEAD + ranged GET race to resolve filename/size/resume/etag; torrent metadata resolution.
- **Gaps:** no `dispose` wiring (subscriptions/timers not released). **[S] S4**. Desktop magnet returns `Archive`/0 silently. **[S] S4**.

### F-A13 Mirror subsystem
- **Where:** `lib/core/services/mirror/mirror_selector.dart`, `mirror/mirror_registry.dart`, plus dead duplicates in `lib/core/services/mirror_*.dart` and `engines/`.
- **Functions:** live `MirrorFailover` (`advance` `:98`, `reportSuccess` `:92`, `reportSlowMirror` `:159`, `run` `:173`) `mirror_selector.dart`; `MirrorHealthStore` (`recordFailure/Success/Speed`, `getMirrorRanking`, blacklist) `mirror_registry.dart:65+`; `MirrorBenchmarkService.benchmarkAll` `:826`; `ServerProfileManager` `:654`.
- **Wiring:** `MirrorFailover` constructed inside `HttpTransferJob` `:936/:1907`; `MirrorHealthStore.instance.init()` in `main.dart:373`.
- **Ideal:** rank mirrors by persisted speed/health, fail over on error, benchmark periodically.
- **Gaps:** duplicate/dead classes (`MirrorManager`, `MirrorSelector`, `MirrorParallelEngine`, `mirror_manager.dart`, `mirror_failover.dart`, `mirror_health_store.dart`, `mirror_benchmark_service.dart`, `engines/server_profile_manager.dart`) — real import-swap hazard. **[C] S3**. DI `MirrorHealthStore`/`MirrorRegistry` never resolved; DI instance ≠ `.instance`. **[C] S3**.

### F-A14 Progress handling
- **Where:** `lib/core/services/engine/download_progress_handler.dart`
- **Functions:** `handleWorkerProgress` `:247`; `handleProgress` `:206`; `emit` `:184`; `chunkFingerprint` `:54`; `markDone` `:87`; `_handleUrlExpired` `:105`.
- **Wiring:** HTTP instance created in `HttpDownloadOrchestrator.download` `:233`; called `:315`.
- **Ideal:** normalize worker/torrent maps, throttle emissions, aggregate chunks, handle URL expiry.
- **Gaps:** `handleProgress` `:206`, `handleEngineMessage` `:91`, `handleUrlExpired` `:98` are test-only. **[C] S3**. `HttpDownloadEngine` (adaptive thread monitor) is never given to the handler → adaptive recording dead. **[S] S2**.

---

# Part B — BitTorrent / P2P

Entry: every consumer imports `torrent_service.dart`, which conditional-exports `torrent_service_stub.dart` (web) or `torrent_service_ffi.dart` (VM). Pinned `libtorrent_flutter: 1.9.2`.

### F-B1 `TorrentService` façade (FFI)
- **Where:** `lib/core/services/torrent_service.dart`, `lib/core/services/torrent_service_ffi.dart`
- **Functions:** `init()` `:264`; `dispose()` `:697`; `pauseTorrent` `:1114`; `resumeTorrent` `:1185`; `addMagnet` `:770`; `addMagnetWithMetadataTimeout` `:825`; `addTorrentFile` `:950`; `removeTorrent` `:1004`; `saveResumeData` `:644`; `saveAllResumeData` `:668`; `getFiles` `:1283`; `getAccurateFileProgress` `:1491`; `getPeers` `:1722`; `torrentUpdates` `:1356`; `alertUpdates` `:1368`; tracker CRUD `:1372-1409`; `configureSession` `:385`; `shouldStopSeeding` `:1563`; `createTorrent` `:1411`.
- **Wiring:** DI `injection.dart:104-107`; injected into `TorrentDownloadHandler`, `TorrentDownloadOrchestrator`, `TorrentProvider`, `TorrentSessionManager`; app startup `main.dart:305-345`.
- **Ideal:** full libtorrent v1/v2 client: DHT/PEX/UPnP, encrypted peers, sequential streaming, resume, seeding policy.
- **Status/gaps (many are constraints of the pinned 1.9.2 bridge):**
  - Hardcoded capability flags (`resumeDataSupported=false`, `filePrioritiesSupported=false`, `trackersSupported=false`, etc.) `:104-130`; not derived from the loaded bridge. **[C] S2**
  - `nativeVersion => '2.1.1'` false `:1877`. **[C] S4**
  - `getRecentAlerts` always `const []` `:1370`; `getTorrentSnapshot` always `null` `:1874`. **[C] S3**
  - Fire-and-forget locking in `addMagnet`/`addTorrentFile`/`removeTorrent` `:808/:963/:1011`. **[S] S2**
  - Magnet `resumeData` forwarded to native but **ignored** by `LibtorrentNativeImpl.addMagnet` `:292`. **[C] S2**
  - `dhtBootstrapNodes` never reach native. **[C] S2**
  - `downloadAndApplyBlocklist` always false (native IP filter stub). **[C] S3**
  - `_alertController` never closed in `dispose`. **[C] S4**

### F-B2 `LibtorrentNativeImpl` (native bridge)
- **Where:** `lib/core/services/torrent/libtorrent_native_impl.dart`
- **Functions:** `init` `:246`; `_mapStatus` `:87`; `addMagnet/addTorrentFile` `:292/:300`; `pauseTorrent/resumeTorrent` `:318/:324`; `getFiles` `:362`; `setFilePriorities` `:376`; `configureSession` `:428`.
- **Ideal:** thin mapping over `libtorrent_flutter` with real progress/tracker/resume/peer support.
- **Gaps:** many stubs (`getFileProgress` `:389`, `getPeers` `:396`, `saveResumeData` `:403`, `loadResumeData` `:413`, `getTrackers` `:489`, `setSequentialDownload` `:514`, `createTorrent` `:532`, `loadIpFilter` `:546`, proxy/SSL webseeds). **[C] S2/S3**. Piece counts fabricated from `totalWanted/262144` `:84-113` (UI labels "est."). **[C] S2**. `isBridgeCompatible => true` unconditional `:42`.

### F-B3 Torrent resume store
- **Where:** `lib/core/services/torrent_resume_store.dart`
- **Functions:** `registerSource/unregisterTorrent` `:102-126`; `saveAndWait` `:155`; `saveAllDebounced/saveAll` `:328/:363`; `loadResumeDataForSource` `:423`; `loadDegradedSnapshotForSource` `:474`; `validateResumeData` `:688`; `needsRecheckAfterResume` `:713`.
- **Wiring:** `TorrentService` pause/resume paths; `TorrentDownloadHandler`; `TorrentSessionManager`; `download_torrent_mixin`.
- **Ideal:** content-addressed, SHA-256-verified, crash-safe resume snapshots keyed by info-hash.
- **Gaps:** `shouldWriteBlob=false` path can reference an absent blob. **[C] S4**. `_stableKey` only parses HTTP `.torrent` files `<2 MB` → larger torrents key on URL. **[S] S4**. `validateResumeData` checks only size. **[C] S4**.

### F-B4 `TorrentDownloadHandler` (engine, 2960 lines)
- **Where:** `lib/core/services/engine/torrent_download_handler.dart`
- **Functions:** `handleTorrentDownload` `:793`; `haltTorrent` `:416`; `removeActiveTorrent` `:395`; `_subscribeToUpdates` `:2115`; `_detectCompletion` `:2837`; watchdogs `:1953`; `computeAdaptiveSyncInterval` `:672`.
- **Wiring:** DI `injection.dart:108`; `DownloadEngine` `:521`; subscriptions via `TorrentSubscriptionRegistry`.
- **Ideal:** add magnet/torrent, track metadata, per-file accurate progress, completion gating, stall/aliveness watchdogs.
- **Gaps:** stale-handle cleanup with `deleteFiles=true` can't delete (no `savePath` in `TorrentUpdateInfo`) `torrent_service_ffi.dart:1015`. **[C] S3**. `_saveResumeDataBeforePause` always degraded (flag false) `:535`. **[C] S2**. Recovery recheck can trigger on estimated piece counts `:2443`. **[C] S2**.

### F-B5 Torrent queue, seeding & ratio
- **Where:** `lib/features/downloads/provider/mixins/download_torrent_mixin.dart`, `lib/core/services/torrent_seeding_manager.dart`, `lib/features/downloads/provider/torrent_lifecycle_manager.dart`
- **Functions:** `startSeedingTorrent` `:63`; `updateActualTorrentUploadLimit` `:375`; `updateTaskSeeding` `:487`; `checkTorrentRatioLimits` `:627`; `enforceTorrentQueue` `:689`; `TorrentSeedingManager.checkSeedingPolicies` `:70`; `AdaptiveSeedingPolicy` `:258`.
- **Ideal:** obey max active downloads/seeds, ratio/time/charging/Wi-Fi seeding policy, adaptive upload limits.
- **Gaps/bugs:**
  - `TorrentSeedingManager.startSeedingCheck()` **never called** → periodic seed policy loop dormant. **[C] S2**
  - `updateActualTorrentUploadLimit` else-branch sets `setUploadLimit(0)` labelled "Effectively 0" `:423` — in libtorrent `0` = **unlimited**. **[C] S2**
  - `TorrentLifecycleManager` dead; `enforceQueue` no-op. **[C] S3**
  - `getTorrentFileActualBytes` can return `-1` for unknown files. **[C] S4**
  - `markTorrentFilesCompleted` can overwrite genuinely incomplete rows. **[C] S4**
  - `addWebSeed`/`removeWebSeed` in-memory only, lost on restart. **[C] S3**

### F-B6 Torrent progress/file normalization
- **Where:** `lib/core/services/engine/torrent_file_normalizer.dart`, `lib/core/domain/torrent_file_progress_estimator.dart`
- **Functions:** `normalizeTorrentFile(s)` `:41/:91`; `computeOverallProgress` `:185`; `formatFilesSummary` `:213`; estimator `updateFilesWithNativeProgress` `:18`; `distributeEstimatedBytesSequential` `:112`; `reconcileEstimatedFiles` `:205`.
- **Ideal:** never treat native size 0 as "empty"; estimate per-file bytes only when engine progress unavailable and mark them estimated.
- **Gaps:** files-with-no-selection fallback can contradict selection semantics `:143-156`. **[S] S4**. Estimates can show non-zero progress for zero real bytes. **[C] S4**

### F-B7 Torrent creator, trackers, disk/resource managers
- **Where:** `lib/features/torrent_create/screens/create_torrent_screen.dart`, `tracker_manager.dart`, `torrent_tracker_optimizer.dart`, `torrent_disk_manager.dart`, `torrent_resource_manager.dart`
- **Ideal:** in-app `.torrent` creation; tracker ranking/reannounce; RAM/piece-size heuristics; resource caps.
- **Gaps:** `CreateTorrentScreen` is **not routed anywhere** `[C] S3` and `createTorrentSupported=false`. `TrackerManager` is bookkeeping only (native stubs) and `DetailsScreen` uses its own instance, not DI `details_screen.dart:2343` `[C] S3`. `TorrentTrackerOptimizer`, `TorrentDiskManager`, `TorrentResourceManager`, `magnet_cache_service.dart`, `torrent_models.dart` (duplicate), `torrent/torrent_state_adapter.dart`, `engine/torrent_session_events.dart`/`state.dart` are all dead. **[C] S3**

### F-B8 Torrent details UI
- **Where:** `lib/features/details/widgets/*`
- **Functions:** `TorrentFilesPanel` (toggle/priority/delete/select-all) `torrent_files_panel.dart:12+`; `PeerPanel` `:35`; `TorrentHealthIndicator.calculateHealth` `:22`; `TorrentStatsDashboard` `:6`; `TrackerPanel` `:7`; `TorrentAdvancedSettingsSheet` `:10`.
- **Ideal:** per-file selection/priorities, peer/swarm view, speed graph, tracker management, web-seed/proxy/SSL controls.
- **Gaps:** `TorrentSpeedGraph` dead (no importer) `[C] S3`. `TorrentAdvancedSettingsSheet` unreachable (all 3 capability flags false) `details_screen.dart:2587` `[C] S3`. `PeerPanel` per-peer list never populated (native `getPeers` stub) `[C] S3`. `TrackerPanel` always shows "unavailable". `PeerInfo` never constructed outside tests.

---

# Part C — Downloads Orchestration & State

Live source of truth: `DownloadProvider` + `DownloadOrchestrator` + 4 mixins. The parallel provider layer (`DownloadListProvider`, `DownloadQueueProvider`, `DownloadFilterProvider`, `DownloadStatsNotifier`, `DownloadStateNotifier`, `DownloadCoordinator`) is **removed from DI and the widget tree** (`injection.dart:137-141`) and is test-only.

### F-C1 `DownloadProvider` (live notifier)
- **Where:** `lib/features/downloads/provider/download_provider.dart` (1795 lines)
- **Functions:** `load()` `:387` (journal replay + disk reconcile + restart→paused); `addTask` `:870`; `setTaskState` `:900`; `addDownload` `:1128`; `addDownloadsBatch` `:1227`; `addBatchDownloads` `:1254`; `startTask` `:1294`; `pauseTask` `:1297`; `resumeTask` `:1367`; `cancelTask` `:1390`; `deleteTask` `:1413`; `retryTask` `:1494`; `clearHistoryTasks` `:1571`; `startOverTask` `:1721`; host contract `:1621-1757`.
- **Wiring:** constructed `main.dart:222`, registered as singleton `:233`, mounted `:472`; consumed by home/details/history/categories/browser/add-download.
- **Ideal:** single reactive task store; DB-first writes; queue pump; retry/backup; torrent integration.
- **Gaps/bugs:**
  - Override `updateTaskSeeding` `:982` shadows mixin and **drops** `updateActualTorrentUploadLimit()`/`providerStartWidgetTimer()`. **[C] S2**
  - `currentDownloadSpeed` defined in both provider `:266` and `download_filter_mixin.dart:97`. **[C] S4**
  - Two parallel state-persistence paths (`_applyStateChange` + snapshot store vs `TaskExecutor.onTransitionHook`); `_onDomainEvent` ignores the event type `:380`. **[C] S4**
  - Cancel/completed transitions can request `completed→failed`, forbidden by the matrix → debug `InvalidTransitionError` `cancelTask`/`markCompletedFileMissing`. **[S] S2**
  - Widget/live-activity sync is a no-op (`updateTelemetryWidget` `:1667`; `_widgetUpdateTimer` never assigned). **[C] S3**
  - Batch ops are sequential awaits `:1097-1136`. **[S] S4**

### F-C2 `DownloadOrchestrator` (lifecycle engine, 5448 lines)
- **Where:** `lib/features/downloads/provider/download_orchestrator.dart`
- **Functions:** `startTask` `:499`; `_startTaskBody` `:3556`; `_resolveStreamUrl` `:622`; `_executeDownload` `:1928`; `_finalizeDownload` `:1516`; `_mergeAudioVideo` `:926`; `retryMergeOnly` `:1402`; `errorMessage` `:4929`; `isRetryableError` `:4966`.
- **Wiring:** constructed in `DownloadProvider` ctor `:113`; invokes `IDownloadEngine.download`.
- **Ideal:** policy gates (wifi/cellular/charging), resume validation, YouTube stream refresh, parallel video+audio, merge, checksum + integrity gate, completion + MediaStore.
- **Gaps:** `_orphanCleanupTimer` callback empty `:138-141` → does nothing. **[C] S3**. `onProgressTick()` never called `:288`. **[C] S3**. FFprobe per merge `:1198` (perf). **[S] S4**

### F-C3 Domain state machine & executor
- **Where:** `lib/features/downloads/domain/state_machine/domain_state_machine.dart`, `domain/executor/task_executor.dart`, `domain/commands/download_commands.dart`, `domain/events/download_events.dart`
- **Functions:** `transition` `:203` (throws `InvalidTransitionError` debug `:227`); `TaskExecutor.dispatch` `:85`; `_executeTaskCommand` `:121`; `TaskMailbox` `:9`.
- **Ideal:** authoritative transition matrix with audit log; per-task mailbox with generation/tombstones.
- **Gaps:** `UpdateTaskUrl`/`SetTaskPriority`/`ReorderQueue` are no-ops in the executor `:289-295/:114`. **[C] S3**. Throwaway state machines built in `_applyStateChange` and `NetworkMonitor` are leaked. **[C] S4**

### F-C4 Queue pump
- **Where:** `lib/features/downloads/provider/mixins/download_queue_mixin.dart`, `provider/download_queue_engine.dart`
- **Functions:** `pumpQueue` `:177`; `_executePumpLocked` `:196`; `reorderTasks` `:139`; `boostTaskPriority` `:351`.
- **Ideal:** pump while slots available; order `appUpdate → priority → queueOrder → createdAt`.
- **Gaps:** live `DownloadQueueEngine` only feeds dead code; `updateTasksBulk` not used by batch ops. **[C] S3**

### F-C5 Scheduling
- **Where:** `lib/features/downloads/provider/schedule_manager.dart`
- **Functions:** `callbackDispatcher` `:13`; `initialize` `:117`; `scheduleAlarm` `:133`; `cancelAlarm` `:157`; `scheduleNextDynamicTick` `:169`; `checkScheduledDownloads` `:224`.
- **Ideal:** in-app 15 s dynamic tick **plus** OS-level Workmanager one-off alarms so scheduled downloads fire while app is killed; daily/weekly repeat.
- **Gaps:** `initialize()`/`scheduleAlarm()`/`cancelAlarm()` **never called** → OS-level scheduling non-functional. **[C] S2**. `ScheduleRepeat` daily/weekly never re-armed (no field on `DownloadTask`). **[C] S2**. Scheduled-start notifications never fire (`onScheduledTaskStarted` not passed). **[C] S2**

### F-C6 NetworkMonitor
- **Where:** `lib/features/downloads/provider/network_monitor.dart`
- **Functions:** `init` `:99`; `checkNetworkConnectivity` `:156`; `_pauseForNetworkDisconnect` `:218`; `_pauseForWifiOnly` `:292`; `_resumeWaitingForWifi` `:339`.
- **Ideal:** pause on disconnect/wifi-only, auto-resume on reconnect without resuming user-paused tasks.
- **Gaps:** `_resumeWaitingForWifi` resumes any task whose error text matches, ignoring original pause cause. **[S] S2**. `markWifiWaiting` set never consumed. **[C] S4**

### F-C7 Notifications coordinator
- **Where:** `lib/features/downloads/provider/notification_coordinator.dart`
- **Functions:** action handler `:229`; `showProgress` `:375`; `showComplete` `:325`; `showFailed` `:451`; `_postGroupSummary` `:429`.
- **Ideal:** per-task progress with pause/resume/cancel actions, group actions, quiet-hours muting, screen-off throttling.
- **Gaps:** `showScheduledStarted` only reachable via unwired `onScheduledTaskStarted` `:354`. **[C] S3**

### F-C8 Data & models
- **Where:** `lib/features/downloads/data/drift_task_repository.dart`, `drift_task_snapshot_store.dart`, `models/download_task.dart`
- **Functions:** `DownloadTask` with `transitionTo` `:776`, `copyWith` `:823`, `toMap` `:1069`; `DriftTaskRepository` CRUD `:14-57`.
- **Ideal:** typed task model with validated transitions and full serialization.
- **Gaps:** `watchTask/watchAll` are one-shot synthetic streams, not reactive `:46-54`. **[S] S3**. `provider/task_repository.dart` is a dead duplicate. **[C] S3**. `DownloadConfig` model dead. **[C] S3**

### F-C9 Downloads widgets
- **Where:** `lib/features/downloads/widgets/*`
- **Live:** `DownloadCard` `:46`, `DownloadStatsPanel` `:12`, `FilterChipsBar` `:38`, `BatchOperationsSheet` `:13`, `ChannelProgressPainter`.
- **Dead:** `QueueReorderWidget`, `SchedulePickerWidget`, `TorrentMetadataProgress`, `SpeedGraphWidget`, public `StatusChip`. **[C] S3**

### F-C10 Backup/restore & third-party import
- **Where:** `lib/features/downloads/provider/mixins/download_backup_mixin.dart`
- **Functions:** PBKDF2 + AES-256-CBC + HMAC `:41-179`; `exportBackupJson` `:184`; `importBackupJson` `:201`; aria2/IDM/JDownloader import `:369/:415/:459`.
- **Ideal:** encrypted full backup (settings + tasks + bookmarks) with merge/replace.
- **Gaps:** export serializes **only download tasks**, not settings/bookmarks, despite UI copy. **[C] S2**. `DownloadBackupService` is a dead duplicate. **[C] S3**

---

# Part D — In-App Browser

The subsystem contains **two parallel implementations**: the live `screens/browser_screen.dart` + `part` mixins (which instantiate services directly), and a fully-built but **never-instantiated** "REFACTOR B" facade (`services/browser_controller.dart`, `NavigationController`, `BrowserTabController`, `BrowserDownloadCoordinator`, and orphan widgets). The dead facade is the single biggest structural gap.

### F-D1 Browser screen & mixins (live)
- **Where:** `lib/features/browser/screens/browser_screen.dart`, `browser_screen_base.dart`, and part files (`_lifecycle`, `_tabs`, `_webview`, `_navigation_menu`, `_popups_ads`, `_media_downloads`, `_dashboard`, `_build`, `_shortcuts`, `_indicators`, `_misc_widgets`, `_radar_signal`)
- **Functions:** `_BrowserScreenStateBase` owns `_tabManager` `:764`, `_sniffer` `:780`, `_historyManager` `:152`, `_interceptor` `:159`, `_adBlocker` `:137`, `_redirectGuard` `:139`, `_siteSettingsStore` `:144`, `_inactivityWatchdog` `:421`, `_fingerprintManager` `:446`, `_scriptInjector` `:448`; mixins expose `_onPageStart/Stop` `_webview:234/:358`, `_switchTab` `_tabs:127`, `_navigateToUrl` `_navigation_menu:203`, `_showTabSwitcher` `_tabs:701`, etc.
- **Wiring:** entry point `main_navigation_container.dart:62`; WebView host `screens/browser_tab_view.dart`.
- **Ideal:** multi-tab Chromium browser with adblock, sniffer, reader, privacy, userscripts, exact UI wiring.
- **Gaps:** `PageIntentClassifier.instance.init()` never called live (only in dead controller) → persisted classifier config never loaded. **[C] S2**. Dead state `_zeroNotifier`/`_blockedAdsNotifiers` `base:92-96`. **[C] S3**.

### F-D2 Tabs & tab groups
- **Where:** `lib/features/browser/services/tab_manager.dart`, `models/browser_tab*.dart`, `screens/browser_screen_tabs.dart`
- **Functions:** `TabManager.addTab/closeTab/evictInactiveTabs/evictStaleAdTabs/saveTabs/restoreTabs` `:232-661`; `BadgeTab` composition.
- **Ideal:** LRU tab eviction, suspension for RAM, session restore (Drift + prefs), incognito isolation, tab groups.
- **Gaps:** `TabGroup` model + `BrowserTab.tabGroupId` **never set by any live code** → tab groups feature dead. **[C] S3**. Restore from Drift is destructive (`loadAndClearOpenTabs`). **[S] S2**. `evictInactiveTabs` nulls controllers without disposing when already suspended `:127`. **[S] S4**. `_showRecentlyClosedSheet` unreachable (no menu entry). **[C] S3**

### F-D3 Ad blocker
- **Where:** `lib/features/browser/services/ad_blocker_service.dart`, `ad_blocker_delegate.dart`, `adblock_filter_updater.dart`, `filter_line_parser.dart`, `custom_adblock_store.dart`
- **Functions:** domain blocking + `shouldBlockUrl` `:620`; `dynamicAdBlockJs` `:307`; `antiDetectJs` `:935`; `scriptletJs` `:1099`; `youtubeEarlyJs` `:1528`; `cssRulesForUrl` `:1613`; updater `updateIfNeeded` `:366`, `matchesUrlPath` `:739`; `CustomAdBlockStore.addHosts` `:105`.
- **Wiring:** delegate `base:137`; injection in `_onPageStart` `webview:341`; `shouldInterceptRequest` `browser_tab_view.dart:367`.
- **Ideal:** EasyList-class rule engine + cosmetic filtering + anti-adblock circumvention + auto-updating filters.
- **Gaps:** `intervalCleanupJs` no-op `:1516` but still injected. **[C] S3**. `AdBlockFilterUpdater.startAutoUpdateScheduler` never started → auto-update only a 7-day check. **[C] S2**. `AdBlockerDelegate.injectInto` (CSS) never called live. **[C] S3**. `CustomAdBlockStore` has **no UI** (cannot add hosts or toggle custom-only). **[C] S3**

### F-D4 Media sniffer & download interception
- **Where:** `lib/features/browser/services/media_sniffer.dart`, `download_interceptor.dart`, `browser_detector.dart`, `page_intent_classifier.dart`
- **Functions:** `MediaSniffer.scanPageMedia` `:178`, `scheduleScan` `:142`, `clearAll` `:70`; `DownloadInterceptor.verifyContentType` `:164`, `shouldIntercept` `:274`, `startDirectDownload` `:308`; `BrowserDetector.detect` `:128`; `PageIntentClassifier.classifyWithContextAsync` `:445`.
- **Ideal:** detect MP4/WebM/HLS/DASH + YouTube across pages, verify content before download, suggest downloads, block ad-popups.
- **Gaps:** `detectedPlaylistUrls` never written → playlist FAB branch unreachable. **[C] S3**. `ytDetectionFailed` never written → retry FAB branch unreachable. **[C] S3**. `interceptBatch`/`queueDownload`/`recordIntercepted` unused. **[C] S3**

### F-D5 Reader mode, find-in-page, screenshot, PiP, privacy dashboard
- **Where:** `services/reader_extractor.dart`, `reader_html_builder.dart`, `reader_mode_service.dart`, `screenshot_service.dart`, `picture_in_picture_service.dart`, `privacy_dashboard.dart`, `browser_find_panel.dart`
- **Functions:** `ReaderExtractor.extract` `:146`; `ReaderHtmlBuilder.build` `:6`; `ScreenshotService.captureFullPage` `:19`; `PictureInPictureService.enterPiP` `:21`; `PrivacyDashboard.recordBlocked` `:20`.
- **Ideal:** distraction-free reader (themes/typography), full-page screenshot, PiP media, per-site blocked stats.
- **Gaps:** `captureFullPage` only in dead code; live `_capturePage` viewport-only. **[C] S3**. `PictureInPictureService` **zero call sites**. **[C] S3**. `PrivacyDashboard` **zero call sites**. **[C] S3**. `ReaderModeService.activateReaderMode`/`sanitizeContent` dead (live uses extract+rebuild). **[C] S3**

### F-D6 Fingerprint / privacy / script injection
- **Where:** `services/fingerprint_manager.dart`, `script_injector.dart`, `html_sanitizer.dart`, `element_picker_service.dart`, `site_settings_store.dart`, `browser_preferences_repository.dart`
- **Functions:** `FingerprintManager.resolveUserAgent` `:65`, `fingerprintHideJs` `:24`; `ScriptInjector.injectAllScripts` `:546`; `ElementPickerService.pickerScript` `:2`; `SiteSettingsStore.getForHost/saveForHost` `:83/:88`.
- **Ideal:** UA spoofing + canvas/WebGL poisoning injected at document-start on every navigation; per-site zoom/desktop/adblock/custom JS/CSS.
- **Gaps:** fingerprint JS not guaranteed document-start on subsequent navigations. **[S] S2**. `XDM_Autofill` bridge never defined live → autofill **save** dead (fill still works). **[C] S2**. Per-site `customJs/customCss/desktopMode/adBlockEnabled` never written live (only `zoomLevel`). **[C] S2**. Persisted zoom never re-applied on navigation. **[C] S2**. Repo key mismatch `browser_media_sniffer_enabled` vs live `browserSnifferEnabled`. **[C] S4**

### F-D7 History, bookmarks, site settings
- **Where:** `services/history_manager.dart`, `history_export_service.dart`, `widgets/bookmark_manager_screen.dart`, `widgets/browser_history_sheet.dart`, `core/services/database/repositories/*`
- **Functions:** `BrowserHistoryManager.recordHistory` `:45`, `recordVisit` `:150`, `getRecentHistory` `:162`; `BookmarkRepository` CRUD; `BrowserHistoryRepository.addBrowserHistory` `:72`, `flushPendingHistory` `:99`.
- **Ideal:** deduplicated visit history with title/time updates, folders, search, export, bounded retention.
- **Gaps:** **confirmed wrong-row-update bug** — deferred `addBrowserHistory` returns `1`, manager stores `id:1`, later updates the wrong row `history_manager.dart:86,92,110`. **[C] S2**. Search is case-sensitive `:35`. **[C] S4**

### F-D8 Userscripts & custom CSS
- **Where:** `lib/core/services/user_script_manager.dart`, `lib/core/domain/models/user_script.dart`, `screens/script_manager_screen.dart`
- **Functions:** `load` `:33`; `add/update/remove/toggle` `:204-232`; `scriptsForUrl` `:248`; `getJsForUrl` `:401`; `_buildSandbox` `:257`.
- **Ideal:** validated, sandboxed userscripts with per-script permissions (network/cookies/dom), glob URL matching.
- **Gaps:** `ScriptManagerScreen` add/edit/delete calls are **uncaught** → validation throws into async gap `:97,123,162`. **[C] S2**. Permission controls not rendered → users can't grant network/cookies `:`. **[C] S2**. Validator false-positives on legitimate JS. **[S] S4**. Sandbox mutates page prototypes. **[S] S2**

### F-D9 Dead "REFACTOR B" surface
- **Where:** `services/browser_controller.dart`, `navigation_controller.dart`, `browser_tab_controller.dart`, `browser_download_coordinator.dart`, `tab_manager.dart` consumers, `data/browser_preferences_repository.dart`, `widgets/browser_toolbar.dart`, `browser_menu_button.dart`, `browser_misc_dialogs.dart`, `browser_tab_strip.dart`, `browser_tab_switcher.dart`, `widgets/browser_tab_view.dart`, `browser_home_dashboard.dart`, `browser_find_panel.dart`, `browser_sheet_scaffold.dart`
- **Status:** all **zero external references** from the live screen. **[C] S3**
- **Ideal:** either delete the dead facade or migrate the live screen to it (it already contains the richer features: PiP, privacy dashboard, full screenshot, full menu, blocked-URL dialog).

---

# Part E — Add Download, YouTube & Cloud

### F-E1 `AddDownloadDialog`
- **Where:** `lib/features/add_download/widgets/add_download_dialog.dart`
- **Functions:** `show` `:49`; `wasRecentlyAdded/recordAddedUrl` `:71/:76` (30 s dedupe); `_onUrlChanged` `:211`; `_pasteFromClipboard` `:595`; `_resolveLinkMetadata` `:662`; `_handleDuplicateOrSubmit` `:962` (multi-line bulk `:976`, duplicate dialog `:1218`, normal add `:1500`).
- **Wiring:** callers `main_navigation_container.dart:280`, browser screens, `share_url_handler.dart:158`, `home_screen.dart:1110`.
- **Ideal:** paste/type a URL → resolve metadata → choose quality/torrent files → add with auth/headers, dedupe, bulk.
- **Gaps/bugs:**
  - Bulk multi-line path **drops auth + custom headers** `:1051-1131`. **[C] S2**
  - "Add Numbered" duplicate path drops auth/headers `:1433`. **[C] S2**
  - `_isSubmitting` sticks true when bulk quality sheet dismissed `:988`. **[C] S2**
  - Stale `_resolvedThumbnailUrl`/`_resolvedYoutubeQualityPreset` on URL change `:250-266`. **[S] S4**
  - Bulk quality-preset matching compares strings exactly → chosen quality may be ignored `:1035`. **[S] S2**
  - `AddDownloadViewModel` is **dead** (no importers). **[C] S3**

### F-E2 Media quality sheet
- **Where:** `lib/features/add_download/widgets/media_quality_sheet.dart`
- **Functions:** `show` `:23`; `_processAndMemoizeStreams` `:100`; `_fetchStreams` `:193`; `_streamTile` `:831`; alias `YoutubeQualitySheet` `:982`.
- **Ideal:** list resumable video/audio/combined streams with sizes, let user pick.
- **Gaps:** `MediaQualityViewModel` dead. **[C] S3**. Cookie fetch on every open/retry `:196` (slow). **[S] S4**. Index-based audio pairing ignores bitrate. **[S] S4**

### F-E3 YouTube playlist sheet
- **Where:** `lib/features/add_download/widgets/youtube_playlist_sheet.dart`
- **Functions:** `show` `:33`; `_fetchPlaylist` `:139`; `_startBatchDownload` `:198`; `_qualityOptions` `:91`.
- **Ideal:** paginate playlist, multi-select, enqueue batch downloads, return a result.
- **Gaps:** `PlaylistDownloadResult` **never returned** — `_startBatchDownload` pops with no result `:286`, so all callers' "N enqueued" UI is unreachable. **[C] S2**. Batch bypasses `addDownload` (no dedupe/category/auth/scheduling) `:198`. **[C] S2**. `_loadMoreVideos` swallows errors `:133`. **[S] S4**

### F-E4 `YoutubeService`
- **Where:** `lib/core/services/youtube_service.dart`
- **Functions:** auth `signIn/signInWithOAuth/refreshOAuthToken/fetchCookiesFromWebView` `:98-149`; detection `isYoutubeUrl/isExtractableMediaUrl/isPlaylistUrl` `:202-324`; `getStreams` `:574`; `getStreamsForAnyUrl` `:621`; `getStreamForVideo` `:766`; `getPlaylistDetails` `:889`; `refreshStreamUrl` `:1018`; `getFreshStreams` `:1158`; client cool-down API `:40-66`.
- **Wiring:** `init()` `main.dart:385`; used by orchestrator (`:670,687,2887,...`), provider `:1513`, add-download, media sheet, share handler.
- **Ideal:** resolve streams via backend with cookies/OAuth, fallbacks, playlists, fresh-URL refresh.
- **Gaps:** OAuth token not persisted → `hasOAuth` false after restart. **[C] S2**. `resetClient()` no-op `:141`. **[C] S3**. Dead API: `getPlaylistInfo`, `getPlaylistVideos`, `qualityLadderDistance`, `evaluateQualityDowngrade`, all cool-down methods. **[C] S3**. Timeout message mismatch (`35s` vs `45s`). **[C] S4**

### F-E5 XDM backend client
- **Where:** `lib/core/services/xdm_backend_client.dart`, `backend_health_service.dart`, `xdm_backend_exceptions.dart`
- **Functions:** `loadApiKey` `:87`; `refreshConfig` `:204`; `health` `:225`; `getStreams` `:276` (10-min LRU + expiry eviction + rate limit + circuit breakers); `getPlaylist` `:440`; `search` `:528`; SSL pinning `_configureDioSSL` `:732`.
- **Ideal:** resilient multi-backend stream API with caching, retries, health-based failover, TLS pinning.
- **Gaps:** `_buildHeaders` returns `'Bearer '` when no key instead of throwing `:242`. **[C] S4**. SSL pinning hashes full-cert DER vs claimed SPKI digests `:747`. **[S] S2**. `lib/core/models/xdm_backend_models.dart` is entirely dead. **[C] S3**

### F-E6 `FFmpegMuxService`
- **Where:** `lib/core/services/ffmpeg_mux_service.dart`
- **Functions:** `dynamicTimeout` `:29`; `canResumeMerge` `:35`; `mergeVideoAudio` `:49`; `_buildArgs` `:131`; `_canStreamCopy` `:229`; `_validateOutput` `:280`.
- **Wiring:** `download_orchestrator.dart:1221`.
- **Ideal:** mux separate video+audio into one file, preferring stream-copy; validate output.
- **Gaps:** `_validateOutput` requires both streams → video-only merges rejected `:298`. **[S] S2**. `canResumeMerge` only checks existence `:35`. **[S] S4**

### F-E7 Remote API, site intelligence, share/clipboard
- **Where:** `lib/core/services/remote_api_service.dart`, `site_intelligence/*`, `clipboard_service.dart`, `share_service.dart`, `share_url_handler.dart`
- **Functions:** `RemoteApiService.start` `:99` (loopback HTTP control API); `SiteIntelligenceService.analyzeUrl/analyzeMagnet/resolveCategory` `:346-603`; `ClipboardService.checkClipboardForUrl` `:94`; `ShareService.init/handleUrl` `:40/:71`; `ShareUrlHandler.handle` `:20`, `handleDeepLink` `:179`.
- **Ideal:** optional remote control API, site profiles/magnet analysis, clipboard detection, share/deep-link intake.
- **Gaps:** `RemoteApiService.enabled=false` and never set true → entire remote API inert. **[C] S3**. `SiteIntelligenceService` constructor self-registers in `ServiceRegistry`, but `AddDownloadDialog`/`url_utils` construct **fresh instances per use** → duplicate registrations + repeated prefs reads. **[C] S2**. `url_patterns.magnetHashRegex` cannot parse v2 (64-hex) hashes `:85`. **[C] S2**. Clipboard detection opens the **browser** instead of Add Download `main_navigation_container.dart:238`. **[C] S4**. `ShareUrlHandler.setPauseAll/ResumeAllCallback` never called → `dmx://pause-all`/`resume-all` no-ops. **[C] S2**

---

# Part F — Settings & Resources

### F-F1 `SettingsProvider`
- **Where:** `lib/features/settings/provider/settings_provider.dart`
- **Functions:** `load()` `:591`; `resetToDefaults()` `:1390`; `toTorrentSessionSettings()` `:1761`; `isInQuietHoursNow` `:1344`; `effectiveSpeedLimitBytesPerSecond` `:872`; `setVisualQuality` `:554`; all typed setters.
- **Wiring:** constructed `main.dart:179`; loaded `:180`; `ChangeNotifierProvider` `:471`; consumed across engine/browser/notifications.
- **Ideal:** one validated SharedPreferences + secure-storage settings store, applied live.
- **Gaps/bugs:**
  - `resetToDefaults` sets power flags `false` while first-install defaults are `true` `:1592` vs `:524,525,528,773`. **[C] S2**
  - `setBatteryOptimizationPrompted` does not `notifyListeners()` `:1379`. **[C] S2**
  - `NotificationsSettingsPage` orphaned (no tab). **[C] S3**
  - `SettingsViewModel` never instantiated. **[C] S3**
  - `minSeedTimeMinutes` `:322` has no persistence; always `0`. **[C] S2**
  - `TorrentSettingsMixin` backing fields shadowed by provider fields (conflicting `maxActiveTorrents` 5 vs 3). **[C] S3**
  - Dead settings (persisted+exposed, no consumer): `cleanupDays`, `categoryFolders`, `maxConcurrentFilesPerTorrent`, `useLocalYtFallback`, `maxActiveTorrents`, `maxPeerConnectionsPerTorrent`, `maxHalfOpenConnections`, `useOsCache`, `enableIpFilter/ipFilterPath`, `enableAnonymousMode`, `enableNatPmp/Lpd/Pex/Lsd`. **[C] S3**
  - Torrent proxy/SSL settings never reach the torrent session (`TorrentSessionSettings` carries only 11 fields). **[C] S2**
  - `_maxConcurrentFilesPerTorrent` no upper clamp `:484`; interval setters unvalidated `:1282`. **[S] S4**

### F-F2 Settings screens
- **Where:** `lib/features/settings/screens/*`
- **Functions:** `SettingsScreen` 6 lazy tabs; per-page toggles.
- **Gaps:** Search index maps "Notifications & Alerts"→index 3 (Torrent), "Enable DHT"→index 4 (Advanced), "Developer Mode"→index 6 (out of range) `:399-554`. **[C] S2**. `_mapSectionToIndex` `'appear'` tested twice; `'notif'`→Appearance `:150-174`. **[C] S2**. `_ImageCacheSlider` cannot select Auto(0) `power_settings_page.dart:517`. **[C] S4**

### F-F3 Backup
- **Where:** `lib/features/settings/utils/backup_helper.dart`
- **Functions:** `exportBackup` `:268`, `importBackup` `:289`.
- **Gaps:** label claims settings+bookmarks but export is tasks-only; shares text rather than writing a file. **[C] S2**

### F-F4 App lock / permissions
- **Where:** `lib/core/services/app_lock_service.dart`, `permission_service.dart`, `lib/features/settings/widgets/app_lock_screen.dart`
- **Functions:** `setPin/verifyPin/lockoutRemaining/resetFailedAttempts/disableLock` `:91-274`; `PermissionService.isStoragePermissionValid/ensureStorageAccess/requestBatteryOptimizationExemption` `:60-285`.
- **Ideal:** PBKDF2 PIN with escalation lockout (survives restart), storage/media/battery permission flows.
- **Gaps:** `AppLockService.authenticate()` never called (biometric path dead) `:286`. **[C] S3**. Static class also registered in DI (instance pointless). **[C] S3**

### F-F5 Resources: power, quiet hours, device tier, DB
- **Where:** `lib/core/services/power_monitor.dart`, `quiet_hours.dart`, `device_tier.dart`, `database_service.dart`, `database/*`
- **Functions:** `PowerMonitor.batterySaverMode/throttleFactor/requestIgnoreBatteryOptimizations` `:90,307`; `QuietHours.isInQuietHours` `:6`; `DeviceTierService.detect/recommendedImageCacheMb` `:62`; `DatabaseService.init/saveTaskDebounced/flush` `:62,227,304`; `DatabaseMaintenanceService` `:10`.
- **Ideal:** battery/thermal throttling, quiet-hours muting + bandwidth schedule, RAM-scaled image cache, WAL-tuned Drift DB with periodic maintenance.
- **Gaps:** `DeviceTierService.recommendedIsolateCap` never read `:42`. **[C] S3**. `DatabaseMaintenanceService._maintenanceTimer` never assigned `:14`. **[C] S3**. `AppDatabase.setSynchronousFull/Normal` never called. **[S] S3**

---

# Part G — Subscription

### F-G1 Entitlements & tiers
- **Where:** `lib/core/domain/subscription/*` (`subscription_tier.dart`, `entitlement.dart`, `subscription_plan.dart`, `subscription_status.dart`)
- **Functions:** `SubscriptionTier.free/premium` (free = 3 downloads / 4 threads / no torrent / no ad-removal) `:26-47`; `Entitlement.forTier` `:4`; `SubscriptionPlan.all`; status helpers.
- **Ideal:** a single entitlement source the app gates features on (concurrency, threads, torrent, ads).
- **Gaps:** **no runtime code enforces any entitlement** (torrent support/ads/limits ungated). **[C] S2**

### F-G2 `SubscriptionService`
- **Where:** `lib/core/services/subscription/subscription_service.dart`, `sub_club_api_client.dart`
- **Functions:** `init()` `:90`; `validate()` `:100`; `restorePurchases()` `:135`; `setReceipt` `:161`; `hasEntitlement` `:58`; `effectiveThreadCount` `:72`; `hasReachedDownloadLimit` `:67`.
- **Ideal:** load cached receipt, validate against SubClub, periodic revalidation, keep last-known-good on failure.
- **Gaps:** `init()` **never called** → no validation, always free. **[C] S1**. `_loadCachedStatus`/`_cacheStatus` placeholders persist nothing `:190-208`. **[C] S2**. Uses plain `Dio()` bypassing `DioNetworkPolicy`. **[S] S4**

### F-G3 `PurchaseService`
- **Where:** `lib/core/services/subscription/purchase_service.dart`
- **Functions:** `init` `:67`; `purchase` `:84`; `restorePurchases` `:128`; `isProductAvailable` `:145`; `getProductPrice` `:155`; `completePurchase`/`cancelPurchase` `:203/:223`.
- **Ideal:** platform billing purchase → receipt → validation.
- **Gaps:** `_initiatePlatformPurchase` placeholder `:183`; `purchase()` **always times out after 5 min** unless test hook called `:103`. **[C] S1**. `init()` never called. `isProductAvailable` always true; price hardcoded. **[C] S2**

### F-G4 Subscription UI & routes
- **Where:** `lib/features/subscription/**`, `core/services/subscription/subscription_guard.dart`
- **Functions:** `SubscriptionScreen` `:15`; `SubscriptionProvider` `:10`; `PaywallBottomSheet.show` `:12`; `SubscriptionGuard.checkEntitlement` `:25`.
- **Ideal:** paywall, plan comparison, restore, status banner reachable by named route.
- **Gaps (blockers):**
  - `SubscriptionScreen` calls `context.read<SubscriptionService>()`/`<PurchaseService>()` but **no such providers exist** in the tree → `ProviderNotFoundException` crash. **[C] S1**
  - `/subscription` named route **undefined**; `pushNamed` from guard/paywall falls through to `MainNavigationContainer`. **[C] S1**
  - `SubscriptionGuard` mixin never mixed; `PaywallBottomSheet` never shown. **[C] S3**

---

# Part H — Onboarding, Permissions & App Lock

### F-H1 Onboarding
- **Where:** `lib/features/onboarding/screens/onboarding_screen.dart`
- **Functions:** 5-page animated `PageView` `:166`; `_buildBottomControls` `:340`; Skip/Start → `settings.setShowOnboarding(false)` + `pushReplacement(PermissionRequestScreen)` `:294,445`.
- **Wiring:** `main.dart:531` renders when `settings.showOnboarding`.
- **Ideal:** first-run feature tour, skippable, persisted.
- **Gaps:** decorative graphics not gated by visual-quality; no TODO. **[S] S4**

### F-H2 Permission request
- **Where:** `lib/features/onboarding/screens/permission_request_screen.dart`
- **Functions:** storage/notification/battery cards + download-folder picker; persists `customDownloadPath` `:103`; continue → `MainNavigationContainer` `:247`.
- **Ideal:** collect required permissions and a download folder on Android before first use.
- **Gaps:** initial permission state shows all-denied until first resume `:122`; battery `isPermanentlyDenied` hardcoded false `:338`. **[S] S4**

---

# Part I — UI, Theme, Navigation & Accessibility

### F-I1 Themes & design tokens
- **Where:** `lib/core/app_theme.dart`, `lib/shared/design/dmx_tokens.dart`, `dmx_design.dart`, `dmx_card.dart`, `dmx_feedback.dart`
- **Functions:** dark/AMOLED/light themes `:586-595`; `dataStyle/microLabel` (11sp floor) `:179/:196`; decoration helpers `:407-548`; `CockpitNotchBorder` `:817`; `DmxCardShell/DmxButton/DmxDialog/DmxConfirmDialog/DmxTextField/DmxEmptyState` `dmx_design.dart:36-850`.
- **Wiring:** theme selected `main.dart:497-501`; `DmxCardShell` 23 refs/15 files; `ThemedSnackbar` 125 refs.
- **Ideal:** single Signal Deck token system (spacing/radius/motion/typography), AMOLED + light + dark, high-contrast-aware.
- **Gaps:** two divergent motion-token sets (`AppTheme.motion*` vs `DmxTokens.anim*`). **[C] S4**. `DmxTokens.textXs=9` violates the 11sp floor. **[C] S4**. `DmxCard`, `DmxSectionGroup`, `DmxBanner`, `DmxPressable`, `showMediaChoiceDialog`, `DmxFeedback`, `DmxScaffold` dead. **[C] S3**. Many unused tokens/helpers. **[C] S3**

### F-I2 Navigation
- **Where:** `lib/shared/widgets/main_navigation_container.dart`
- **Functions:** `_buildScreen` (Home/Browser/Settings) `:57`; bottom bar `:463`, tablet bar `:596`, rail `:723`; keyboard `Ctrl+N`/`Ctrl+1..5` `:276-302`; `_FadeIndexedStack` `:384`; app-lock on resume `:158`; update check `:110`; clipboard sniff `:196`.
- **Ideal:** 3-tab responsive navigation (bottom/rail), shortcuts, share/deep-link intake, lifecycle hooks.
- **Gaps:** `Ctrl+4/5` → `setActiveTabIndex(3/4)` while only 3 screens exist → out-of-range `IndexedStack`. **[C] S1**. `setActiveTabIndex` never clamps `download_filter_mixin.dart:295`. **[C] S2**. Several hardcoded English strings/semantics. **[C] S4**

### F-I3 Accessibility
- **Where:** `lib/shared/accessibility/*`
- **Functions:** `HighContrastDetector.isActive` `:9` (live); `XdmAnnouncer.announce` `:27` (1 call site); `XdmTextScaler` `:6` (live); `XdmSemantics` (`progress` used once); `XdmFocus`, `XdmFocusTraversalPolicy`, `XdmMotion` (dead).
- **Ideal:** screen-reader semantics on all widgets, announcements, focus traversal incl. RTL, reduced-motion support.
- **Gaps:** `XdmFocusTraversalPolicy` empty and not RTL-aware despite docs. **[C] S4**. `XdmMotion` effectively dead (only dead `XdmFocus` imports it); doesn't consult `PerformanceMonitor.shouldReduceMotion`. **[C] S3**. `XdmSemantics` strings hardcoded; `heading` ignores `level`. **[C] S4**

### F-I4 Shared widgets
- **Where:** `lib/shared/widgets/*`
- **Live:** `ThemedSnackbar`, `DmxBackdropFilter` (35 refs), `GeometricGridBackground` (21), `NeonGlowButton` (19), `GlassCard`, `SkeletonLoader`, `SectionHeader`, `DmxAppIcon`, `EmptyStateView`.
- **Dead (tests only / zero refs):** `SafeScreen`, `PerformanceMonitorOverlay`, `EnhancedEmptyState`, `FadeInSlide`, `CornerBracketFrame`, `PausableLoopBuilder`, `UnifiedErrorPresenter`. **[C] S3**
- **Gaps/bugs:**
  - `DmxBackdropFilter` fallback paints near-opaque black over parent surfaces `:208-241` (can render dark in light mode). **[S] S2**
  - `AmbientProgress.addRef()` never called → ref-count machinery a permanent no-op; `restartIfMounted` never works. **[C] S3**
  - `ErrorRecoveryWidget` uses **20 missing l10n keys** → raw key strings `:179-232`. **[C] S2**
  - `DmxDivider` uses unguarded `context.watch<SettingsProvider>()` (crashes outside provider tree) `:160`. **[S] S2**

### F-I5 Localization
- **Where:** `lib/core/utils/localization.dart`, `lib/core/utils/l10n/app_{en,ar,de,es,fr}.dart`
- **Functions:** `L10n.translate/of/isRtl` `:38/:97/:110`; `translateCategory/translateStatus*` `:120-190`.
- **Ideal:** 5-locale parity with RTL, pluralization, and every UI string localized.
- **Gaps:** `translateCategory/translateStatus*` support only **en + ar**; de/es/fr fall back to English. **[C] S2**. 5 locale files have identical 608 keys (parity) **but 20 keys used in code are missing** (see backlog). **[C] S2**. 228 keys appear unused. **[C] S4**. Many hardcoded strings (`file_opener.dart:16`, `home_screen.dart:1129`, `main_navigation_container.dart:97`). **[C] S4**

### F-I6 Home screen
- **Where:** `lib/features/home/screens/home_screen.dart` (2102 lines)
- **Functions:** Active/Completed tabs; search; analytics pie with tap-to-filter; `FilterChipsBar`; sort menu; reorderable/manual list; multi-column grid; selection mode + batch bar; FAB.
- **Wiring:** `main_navigation_container.dart:60`; reads `DownloadProvider`, `SettingsProvider`.
- **Ideal:** cockpit dashboard with live stats, filtering, batch ops, empty states.
- **Gaps:** local `_selectedTab` independent of provider tab (desync). **[S] S4**. `_DownloadTaskList.build` watches entire `SettingsProvider` `:1608` (perf). **[S] S4**. Hardcoded/Arabic-only strings `:1129`. **[C] S4**

---

# Part J — Platform Services

### F-J1 Notifications
- **Where:** `lib/core/services/notification_service.dart`
- **Functions:** `init` `:330`; `processPendingBackgroundActions` `:260`; `showDownloadProgress` `:531`; `showGroupSummary` `:668`; `showDownloadComplete` `:707`; `showDownloadFailed` `:749`; `cancelNotification/cancelAll` `:837/:845`.
- **Ideal:** 3 Android channels, progress throttle, per-task and group actions, background response bridge.
- **Gaps:** no TODO; wired via `main.dart:220` and `notification_coordinator.dart`. **[C] OK**

### F-J2 Background service
- **Where:** `lib/core/services/background_service.dart`
- **Functions:** `initialize` `:166`; `start` `:672`; `stop` `:711`; `setDownloadActive` `:89`; `reconcileActiveTaskIds` `:112`; `restoreInterruptedTasks` `:939`; `acquireWakeLock/releaseWakeLock` `:787/:912`.
- **Ideal:** Android FGS + iOS BGTaskScheduler; wake-lock renewal; Android 15 dataSync timeout flush/pause; crash recovery.
- **Gaps:** `_heartbeatTimer` never a live timer `:135,729`. **[C] S4**. `onIosBackgroundUnavailable` never invoked. **[C] S3**. `onDataSyncTimeout` never assigned `:549`. **[C] S3**. `onAllDownloadsComplete` never called `:987`. **[C] S3**. iOS native callbacks `initializeMethodCallHandler`/`onBackgroundExpiration` never wired. **[C] S3**

### F-J3 Background scheduler, gate & timer manager
- **Where:** `lib/core/services/background_scheduler.dart`, `background_gate.dart`, `background_timer_manager.dart`, `tick_manager.dart`
- **Functions:** `BackgroundScheduler.registerTask/scheduleBackgroundSync` `:22/:44`; `BackgroundGate.adaptInterval` `:42`; `BackgroundTimerManager.register/pauseAll/resumeAll` `:127-167`; `TickManager.registerTick` `:66`.
- **Gaps:** `scheduleBackgroundSync` is a stub that only calls `markBackground()` `:44`. **[C] S3**. `BackgroundTimerManager._adaptInterval` multipliers disagree with `BackgroundGate.scaleInterval` (`×20/×5/×8/×3` vs `×30/×10/×15/×5`). **[S] S4**. `TickManager` heartbeat depends on broken `DownloadEngine.hasActiveDownloads` (`tick_manager.dart:104`). **[C] S2**

### F-J4 Home-screen widgets & live activity
- **Where:** `lib/core/services/widget_data_bridge.dart`, `widget_data_service.dart`, `widget_deep_link.dart`, `lib/features/downloads/services/download_widget_sync.dart`
- **Functions:** `WidgetDashboard.fromTasks` `:131`; `WidgetDataBridge.pushDashboard` `:244`; `WidgetDeepLinkHandler.handleUrl` `:90`.
- **Ideal:** push a capped dashboard (failed → active → queued → completed) to Android/iOS widgets; deep-link actions back into the app.
- **Gaps:** consumer `DownloadWidgetSync` is **dead** and `updateTelemetryWidget()` is a no-op → dashboard is never pushed. **[C] S2**. `WidgetDataService` (iOS) has no callers `[C] S3`. Deep-link handler itself is wired `main.dart:297`.

### F-J5 Updates, tray, desktop
- **Where:** `lib/core/services/update_service.dart`, `desktop_update_service.dart`, `desktop_tray_service.dart`, `single_instance_service.dart`, `lib/features/settings/widgets/update_dialogs.dart`
- **Functions:** `UpdateService` check; `showUpdateInfoDialog`/`showMandatoryUpdateDialog` `:13/:120`; `DesktopTrayService.init` `:21`.
- **Gaps:** `DesktopTrayService` and all `window_manager`/`tray_manager` desktop UI are **never initialized** → tray/window features non-functional; deps effectively unused. **[C] S3**

### F-J6 Diagnostics, logging, crash reporting
- **Where:** `lib/core/services/diagnostic_service.dart`, `crash_reporting_service.dart`, `logging_service.dart`, `production_telemetry_service.dart`
- **Ideal:** structured logging, Sentry capture, local diagnostics ring buffer, telemetry.
- **Status:** wired in `main.dart`; no major gaps observed. **[C] OK**

---

# Part K — Categories & History

### F-K1 Categories
- **Where:** `lib/features/categories/**`
- **Functions:** `CategoriesScreen` (6 hardcoded category cards + donut) `:15`; `CategoryDetailScreen` (completed/failed filter) `:18`; `CategoriesViewModel.categoryCounts/categorySizes` `:13/:22`.
- **Ideal:** category browser with accurate counts/sizes matching detail.
- **Gaps:** `CategoriesScreen` and `CategoriesViewModel` are **unreachable/dead** (only `CategoryDetailScreen` via deep link). **[C] S3**. `categoryCounts` counts all statuses incl. `Auto`, but detail shows only completed/failed with no `Auto` card → mismatch `download_filter_mixin.dart:136`. **[C] S2**. Case-sensitivity fragility (`filter_chips_bar.dart` lowercases). **[C] S2**. Donut can get an empty sections list with `totalSizeMb>0` `categories_screen.dart`. **[S] S2**

### F-K2 History
- **Where:** `lib/features/history/**`
- **Functions:** `HistoryScreen` (completed+failed list, debounced search, clear) `:17`; `HistoryViewModel` `:6`.
- **Ideal:** searchable transfer history with retention/clear.
- **Gaps:** `HistoryScreen` and `HistoryViewModel` are **unreachable/dead**. **[C] S3**. `historyMaxEntries` setting governs **browser** history, not download history — label misleading. **[C] S4**

---

# Part L — Prioritized Bug / Gap Backlog

Severity: `S1` blocker/crash · `S2` functional defect · `S3` dead/unwired feature · `S4` cleanup/consistency.
`FIXED` marks items resolved in this pass.

## S1 — Blockers / crashes

| # | Item | Location | Status |
|---|------|----------|--------|
| 1 | Ctrl+4 / Ctrl+5 set nav index 3/4, but only 3 screens exist → out-of-range `IndexedStack` | `main_navigation_container.dart:294-301` | FIXED |
| 2 | `SubscriptionScreen` reads `SubscriptionService`/`PurchaseService` providers that don't exist → `ProviderNotFoundException` | `subscription_screen.dart:22-23` | FIXED |
| 3 | `/subscription` named route undefined → paywall never opens | `main.dart:543-583`, `subscription_guard.dart:126,215`, `paywall_bottom_sheet.dart:273` | FIXED |
| 4 | `SubscriptionService.init()` never called → always free; `PurchaseService.purchase()` always times out | `subscription_service.dart:90`; `purchase_service.dart:103,183` | Documented (needs billing SDK) |

## S2 — Functional defects

| # | Item | Location | Status |
|---|------|----------|--------|
| 5 | `DownloadEngine._activeDownloadsCount` never updated → `hasActiveDownloads` always false (breaks TickManager/ambient/glow gating) | `download_engine.dart:54-57` | FIXED |
| 6 | `DownloadProvider.updateTaskSeeding` override drops `updateActualTorrentUploadLimit()` + widget timer | `download_provider.dart:982` | FIXED |
| 7 | `setBatteryOptimizationPrompted` missing `notifyListeners()` | `settings_provider.dart:1379` | FIXED |
| 8 | `resetToDefaults` power-flag defaults drift from first install | `settings_provider.dart:1592` | FIXED |
| 9 | `MediaQualitySheet._isSubmitting` stuck true when bulk quality sheet dismissed | `add_download_dialog.dart:988` | FIXED |
| 10 | `YoutubePlaylistSheet` never returns `PlaylistDownloadResult` → callers' result UI unreachable | `youtube_playlist_sheet.dart:286` | FIXED |
| 11 | `BrowserHistoryManager.recordHistory` stores deferred row id `1` → updates wrong history row | `history_manager.dart:86,92,110` | FIXED |
| 12 | Missing l10n keys (20) render raw key strings (e.g. `retry`, `open_settings`) | `error_recovery_widget.dart:179-232`, `home_screen.dart:474`, browser widgets | FIXED |
| 13 | `updateActualTorrentUploadLimit` sets `setUploadLimit(0)` = **unlimited** when no seeding | `download_torrent_mixin.dart:423` | FIXED |
| 14 | Settings search maps Notifications→Torrent, DHT→Advanced, Developer→out-of-range | `settings_screen.dart:399-554` | FIXED |
| 15 | Bulk multi-line add + "Add Numbered" drop auth/custom headers; bulk preset match brittle | `add_download_dialog.dart:1051-1131,1433` | Documented |
| 16 | `SiteIntelligenceService` constructs fresh self-registering instances per use | `add_download_dialog.dart:221`, `url_utils.dart:136` | FIXED |
| 17 | `url_patterns.magnetHashRegex` can't parse v2 64-hex hashes | `site_intelligence/url_patterns.dart:85` | FIXED |
| 18 | `ScheduleManager.initialize/scheduleAlarm/cancelAlarm` never called → OS-level scheduling dead | `schedule_manager.dart:117,133,157` | Documented |
| 19 | Widget dashboard never pushed (`updateTelemetryWidget` no-op, `DownloadWidgetSync` dead) | `download_provider.dart:1667` | Documented |
| 20 | `DownloadJournal.writeInit/writeCheckpoint` have no callers → recovery loses metadata | `download_journal.dart:1067,1148` | Documented |
| 21 | `TorrentSeedingManager.startSeedingCheck()` never called → seeding policy dormant | `torrent_seeding_manager.dart:25` | FIXED |
| 22 | `ScriptManagerScreen` add/edit/delete uncaught validation errors | `script_manager_screen.dart:97,123,162` | Documented |
| 23 | `XDM_Autofill` bridge not defined live → autofill save dead | `browser_tab_view.dart:150` | Documented |
| 24 | Per-site settings (`customJs/customCss/desktopMode/adBlockEnabled`, zoom re-apply) not wired | `site_settings_store.dart`, `browser_screen_webview.dart` | Documented |
| 25 | Category counts/detail mismatch | `download_filter_mixin.dart:136` | Documented |
| 26 | `RemoteApiService.enabled` never true → remote API inert | `remote_api_service.dart:97` | Documented |
| 27 | `SubscriptionScreen`/Purchase placeholders (see S1#4) | subscription/* | Documented |

## S3 — Dead / unwired features (candidates to delete or complete)

- Parallel download provider layer (`DownloadListProvider`, `DownloadQueueProvider`, `DownloadFilterProvider`, `DownloadStatsNotifier`, `DownloadStateNotifier`, `DownloadCoordinator`).
- Dead download services/widgets (`DownloadBackupService`, `DownloadFilterService`, `DownloadExecutionService`, `DownloadQueueService`, `DownloadNotificationBridge`, `DownloadWidgetSync`, `QueueReorderWidget`, `SchedulePickerWidget`, `TorrentMetadataProgress`, `SpeedGraphWidget`).
- `AddDownloadViewModel`, `MediaQualityViewModel`, `SettingsViewModel`, `CategoriesViewModel`, `HistoryViewModel`.
- `TorrentLifecycleManager`, `TorrentSessionService`, `torrent_models.dart` (duplicate), `torrent/torrent_state_adapter.dart`, `engine/torrent_session_events.dart`, `engine/torrent_session_state.dart`, `magnet_cache_service.dart`, `torrent_disk_manager.dart`, `torrent_resource_manager.dart`, `torrent_tracker_optimizer.dart`.
- Browser "REFACTOR B" surface (`browser_controller.dart`, `navigation_controller.dart`, `browser_tab_controller.dart`, `browser_download_coordinator.dart`, and 8 orphan widgets), `TabGroup`, `PrivacyDashboard`, `PictureInPictureService.captureFullPage`.
- UI dead widgets (`DmxCard`, `DmxScaffold`, `DmxFeedback`, `UnifiedErrorPresenter`, `EnhancedEmptyState`, `FadeInSlide`, `CornerBracketFrame`, `SafeScreen`, `PerformanceMonitorOverlay`, `PausableLoopBuilder`, `XdmFocus`, `XdmFocusTraversalPolicy`, `XdmMotion`).
- `DesktopTrayService` (never initialized).
- `CategoriesScreen`, `HistoryScreen`, `CreateTorrentScreen` (unreachable).
- `NotificationsSettingsPage` (orphaned).
- Mirror duplicate files (`mirror_manager.dart`, `mirror_failover.dart`, `mirror_health_store.dart`, `mirror_benchmark_service.dart`, `engines/mirror_parallel_engine.dart`, `engines/server_profile_manager.dart`).
- `CircuitBreakerRegistry`, `UrlCircuitBreaker`, `ConnectionManager`, `ConnectionWarmer`, `HostConcurrencyRegistry`, `EngineParameterExperiment`, `CancellableDelayer`, `ChecksumService.parseDigestHeader`.

## S4 — Cleanup / consistency

- Duplicate `currentDownloadSpeed`; two state-persistence paths; `_onDomainEvent` ignores event types.
- Duplicate `SiteIntelligenceService` registrations; duplicate `_TorrentFilesPanel` implementations.
- `FileOpener`, `HomeScreen`, `MainNavigationContainer`, `SafeScreen`, error screens hardcode strings.
- `L10n.translateCategory/translateStatus*` only en+ar.
- Two motion-token systems; `DmxTokens.textXs` below 11sp floor.
- `XdmSemantics` hardcoded strings; `heading` ignores `level`; `XdmFocusTraversalPolicy` not RTL-aware.
- `DioClientPool.releaseClient` reserved-count leak; `DmxBackdropFilter` black fallback; `DmxDivider` unguarded provider.
- `minSeedTimeMinutes` unpersisted; many persisted-but-unused settings.

---

# Fix Log

All fixes below are applied and verified: **`flutter analyze lib` — no issues**, **`flutter test` — 2181/2181 passed** (was 2129/52-failing before this work).

## Wave 1 — confirmed functional defects (S1/S2)

1. **`main_navigation_container.dart`** — removed out-of-range `Ctrl+4`/`Ctrl+5` tab shortcuts (only 3 screens exist).
2. **`subscription_screen.dart` / `main.dart`** — subscription services resolved via DI (no more `ProviderNotFoundException`) and `/subscription` route registered.
3. **`download_engine.dart`** — `hasActiveDownloads` now tracks in-flight downloads (restores TickManager / BackgroundGate / ambient gating).
4. **`download_provider.dart`** — `updateTaskSeeding` restored the torrent resume/pause lifecycle + upload-limit + widget-timer side effects.
5. **`settings_provider.dart`** — `setBatteryOptimizationPrompted` notifies; `resetToDefaults` power flags match first-install defaults; `minSeedTimeMinutes` now persisted (was silently always 0).
6. **`add_download_dialog.dart`** — `_isSubmitting` no longer sticks when the bulk quality sheet is dismissed.
7. **`youtube_playlist_sheet.dart`** — returns `PlaylistDownloadResult`; pagination errors surface a snackbar instead of looking like "no more videos".
8. **`history_manager.dart`** — history writes use the immediate path so the correct row id is tracked.
9. **`settings_screen.dart`** — settings search maps to the correct tabs.
10. **`download_torrent_mixin.dart`** — "no seeding" no longer calls `setUploadLimit(0)` (libtorrent 0 = unlimited); applies a ~1 KiB/s cap.
11. **`site_intelligence`** — shared instance instead of per-call construction; magnet regex parses v2/`btmh` hashes.
12. **`torrent_seeding_manager.dart`** — periodic seeding-policy enforcement loop is now started.
13. **l10n** — added the 20 missing keys to all 5 locales.

## Wave 2 — engine, orchestration, browser, platform

14. **Torrent alert handling live** — `download_engine.dart` routes torrents through `TorrentDownloadOrchestrator` (`fastresumeRejected` → verifying, `saveResumeDataFailed` → re-save); orchestrator now forwards `metadataTimeoutSeconds`.
15. **Journal recovery metadata** — `HttpTransferJob` writes `writeInit` (threadCount/totalSize) and periodic `writeCheckpoint` records, so post-compaction crash recovery has accurate metadata.
16. **`DioClientPool`** — `releaseClient` no longer leaks reserved-count entries.
17. **`BandwidthGovernor`** — duplicate cleanup scheduling removed (single mechanism, disposed correctly).
18. **Orphan sidecar sweep** — the previously-empty 60 s timer now deletes `.dmxstate`/`.journal` sidecars only for terminal tasks whose temp file is gone.
19. **`onProgressTick()`** — wired into the periodic resume-save cadence (coalesces parked progress ticks).
20. **OS-level scheduling live** — `ScheduleManager.initialize()` runs on load; `scheduleAlarm`/`cancelAlarm` wired to schedule set/clear; `onScheduledTaskStarted` wired so scheduled-start notifications fire.
21. **Wi-Fi resume correctness** — `NetworkMonitor` resumes only tasks it actually paused for the wifi-only policy.
22. **Widget dashboard live** — `DownloadWidgetSync` wired; `updateTelemetryWidget()` debounces and pushes the real dashboard; state-change hooks call it.
23. **Bulk add auth/headers** — bulk multi-line + "Add Numbered" paths now pass auth/custom headers; bulk quality matching parses heights instead of exact strings.
24. **YouTube OAuth persisted** — token survives restart (secure storage); timeout message matches the real 45 s budget.
25. **Deep links** — `dmx://pause-all`/`resume-all` work via GetIt fallback; clipboard detection now opens Add Download instead of the browser; URL extraction strips trailing brackets/quotes.
26. **Browser** — `XDM_Autofill` bridge registered (autofill save works); `PageIntentClassifier` initialized live; per-site custom JS/CSS injected and per-site zoom re-applied on navigation; dead sniffer FAB branches removed; "Recently closed" menu entry added; incognito menu action opens a real incognito tab; userscript add/edit/delete errors surfaced; sniffer pref key unified; adblock auto-update scheduler started (single path, no double download).
27. **Subscription** — services initialized at startup; purchase fails fast with a clear message instead of a 5-minute hang (pluggable initiator keeps the pipeline testable); disposed-service notifications guarded.
28. **Remote API** — enabled only in developer mode.
29. **Desktop tray** — initialized on desktop platforms with lazy provider callbacks.
30. **UI** — `DmxBackdropFilter` fallback uses theme surface (no black flash in light mode); `DmxDivider` provider-guarded; tab index clamped; `XdmSemantics` localized; `translateCategory`/`translateStatus` extended to de/es/fr.

## Wave 3 — test suite repaired (52 → 0)

31. **Real regressions fixed in lib/manifest/gradle:** AndroidManifest `WidgetActionReceiver` intent-filter restored (package-scoped `UPDATE_WIDGETS` broadcasts were undeliverable); `build.gradle.kts` release-signing gate restored; YouTube merge-failure zombie state (queued forever) fixed in `download_orchestrator.dart`; `verifyApkSignature` sha256-of-file fallback restored; `DiagnosticService.telemetryMetricsSnapshot` cache identity fixed; `CircuitBreaker` P1-8b immediate-probe reverted to the classic contract (transition rejected, next call probes).
32. **Tests aligned with deliberate, git-verified behavior:** burst factor 1.5 (S-01), task-limit 0 = unlimited (P1-1), DownloadTask value-equality/`-1.0`→`isIndeterminate`/YouTube `fileSize` semantics, XDMCRYPT v1 removal (security), DB schema v28, hard-timeout 50 KB/s table, half-open circuit contract, W-9 manifest audit reconciled with H1 (unexported receiver keeps exactly the package-scoped filter), stale golden PNGs regenerated (they were gitignored, pre-styling artifacts), test determinism fixes (pending timers, retry-deletes, disk-space stubs, adblock scheduler timer teardown).

## Remaining known limitations (require external dependencies — documented, not bugs)

- **Purchases disabled (intentional):** `kPurchasesEnabled = false` in `lib/core/services/subscription/subscription_service.dart`. Every install is unlocked at the **highest tier (Premium)** — `SubscriptionService` is constructed unlocked via DI and `init()` also forces it, so no paywall/upgrade UI ever appears and all entitlements/limits are unlimited. `in_app_purchase` was NOT added. To re-enable billing later: flip the flag, wire a store-backed `PlatformPurchaseInitiator` (the hook and `completePurchase`/`cancelPurchase` pipeline already exist and are tested), and add the plugin back.
- **libtorrent bridge caps are now dynamic:** `TorrentNativeCapabilities` (`lib/core/interfaces/i_torrent_native.dart`) is returned by the native bridge; `TorrentService.*Supported` delegates to it. On the pinned 1.9.2 bridge it reports exactly today's values (trackers/peers/resume-blob/IP-filter/torrent-creation/sequential unsupported), so behavior is unchanged — but a future bridge that returns `TorrentNativeCapabilities.all()` auto-unlocks those features with no Dart changes.

## Wave 4 — production hardening

33. **Dead-code removal (S3 list):** deleted ~80 inert lib files and ~42 dedicated tests — the parallel download-provider layer, browser "REFACTOR B" facade + 9 orphan widgets, duplicate mirror classes/files, stale torrent duplicates/utilities, unused view models, orphan settings screen, and unused shared UI/accessibility widgets. `injection.dart` registrations and imports updated. Full suite green after removal (test count 2181 → 2004 because tests for deleted code were removed).
34. **libtorrent capabilities dynamic** (see above) — no longer hardcoded false, enabling automatic unlock on a bridge upgrade.
35. **Purchases disabled / always-highest-tier** (see above) — Premium unlocked from DI construction; purchase UI unreachable.
