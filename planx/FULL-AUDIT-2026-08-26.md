# DMX Full Audit & Master Plan — 2026-08-26

Supersedes the scorecard in `README.md` of this folder (audited against the **current uncommitted working tree**, which includes many fixes landed since the original planx audit). Every finding has a verified `file:line`. Verification basis: `flutter analyze` = clean, `flutter test` = **1924 passed / 3 failed** (failures analyzed below), plus 5 parallel deep-audit passes over every subsystem.

---

## Part 1 — Scorecard (feature-by-feature ratings)

Weighted overall: **~7.1/10** (up from 6.8 at the last audit; global speed limit, torrent session wiring, release-mode jank degrade, device tiers, HTTP auth/headers, and the UI truthfulness layer all landed since then).

| # | Feature | Score | One-line reality |
|---|---|---|---|
| 1 | HTTP download engine | **7.0** | Real segmentation, positional writes, CRC32 WAL journal, `.dmxdone` markers, SHA-256 verify pipeline, mirror failover. Loses points on a proven **resume-corruption bug** (failing e2e test), an unknown-size progress-wipe bug, a per-pause resource leak, and a residual power-loss window. |
| 2 | Torrent engine (libtorrent 1.9.2 FFI) | **5.5** | Core transfer/metadata/pause/recheck/seeding-policy are real and session settings are now genuinely wired. But ~12 ABI-2 features remain stubs (fast-resume, trackers, create, per-file progress, sequential, proxy, web seeds, IP filter) behind an honest capability-gate layer. |
| 3 | State management / DI layer | **6.0** | Excellent rebuild scoping & locking, but **two live DownloadProviders**, three dead providers, and **two dead pipelines** (notification actions, connectivity monitor). |
| 4 | Downloads UI (cards, batch ops) | **8.5** | Scoped selectors, honest metrics, strong delete/undo. Minor watch-leak on torrent cards, one numerator inconsistency for merged YouTube tasks. |
| 5 | Home dashboard / analytics | **7.0** | Great perf engineering; storage analytics counts un-downloaded bytes; pie-touch filter inaccessible. |
| 6 | Details screen | **7.5** | Truthful post-fix, rich panels; speed-chart time axis fabricated for HTTP tasks; a11y gaps on custom buttons. |
| 7 | History / Categories screens | **5.0** | Both standalone screens are **dead code** (unrouted); "Auto" category persists `''` making those views lie by omission. |
| 8 | Theming / design system | **9.0** | Complete token set, 5 themes, AMOLED, motion tokens, min-11sp enforcement. |
| 9 | Browser core (tabs, find, dark) | **7.0** | Deep multi-tab with LRU eviction, crash recovery, edge-swipe. Dual-LRU desync risk, racy JS injection timing. |
| 10 | Incognito / tab groups | **2.0** | Groups absent (dead field). Incognito suppresses history only — cookies/localStorage are shared with normal tabs while the banner claims otherwise. |
| 11 | Ad blocker | **6.0** | Genuine 11-list ABP-subset engine w/ cosmetics + scriptlets + integrity checks. Anti-detect/popup-interceptor layer never injected; simplified semantics cause some over-blocking. |
| 12 | Media sniffer | **5.0** | Detection is genuinely good (DOM + perf-entries, HLS/DASH/mp4). Delivery broken: sniffed streams are never handed to the quality sheet (`preloadedStreams` has no caller). |
| 13 | YouTube extraction + muxing | **7.0** | Strong quality/playlist sheets, FFmpeg stream-copy→HW→SW ladder, expiry refresh. 100% dependent on remote Cloud Run backend (mitigated w/ circuit breakers); quality-fallback sort inverted; rate limiter breaks bulk imports >30 links. |
| 14 | Reader mode | **1.0** | **Broken end-to-end.** Extraction runs, controls appear, nothing ever renders the article; exit path unreachable. Entire render pipeline orphaned. |
| 15 | Add-download flow (batch/auth/headers) | **7.0** | Batch import, Basic-auth + custom headers plumbed end-to-end. Batch path drops headers; dead ViewModels inflate apparent design. |
| 16 | Clipboard monitoring | **6.0** | Works, opt-in, safe defaults, dedupe. Off by default. |
| 17 | Settings system | **8.5** | Global speed limit now genuinely enforced into worker isolates; torrent session flags live; battery-saver cascades real. ~10 persisted-but-dead toggles remain; `resetToDefaults()` misses ~15 keys; HTTPS-only/proxy lack a startup seam. |
| 18 | Persistence (Drift/Hive/backup) | **9.0** | v28 schema, complete migration chain, downgrade-refusal + timestamped backup, resilient converters, encrypted export, careful Hive migration. Proxy password stored plaintext. |
| 19 | Background execution | **7.0** | Foreground dataSync service, wake-lock renewal + escalation, Android-15 6h watchdog handled, iOS BGTask bridge. **Scheduled downloads are dead on Android** (empty Workmanager dispatcher); boot receiver only refreshes widget. |
| 20 | Resource management (power/RAM/jank) | **8.5** | Release-mode frame watchdog + graduated visual degrade, RAM-scaled DeviceTier budgets, real RSS telemetry, token-bucket governor. Residual: cores-only `isLowEndDevice`, hardcoded "60fps" label. |

---

## Part 2 — The 3 confirmed test failures

1. `test/database_migration_test.dart` + `test/database_migration_v1_to_v27_test.dart`
   `Expected: <27> Actual: <28>` — tests hardcode the old schema version; DB bumped to v28 (auth/header columns). **Stale tests, not a product bug.**
2. `test/e2e/download_resume_test.dart` (FIX 16 pause→kill→resume→SHA-256, 4 threads)
   **Real data corruption caught red-handed:** resumed file hash mismatches at offset 0. Log immediately before failure shows `[DMX] H-2: chunk-boundary save failed: Concurrent modification during iteration: _Map len:4.` — direct evidence for bugs C-1/C-2 below.

---

## Part 3 — Consolidated bug list

### P0 — Critical (data loss / headline features dead)

| ID | Bug | Evidence | Scenario |
|---|---|---|---|
| **C-1** | **Resume corruption under concurrency**: `PositionalFileWriter.flushAll()/flushBuffers()` iterate `_handles` without `_metaLock` while `_getHandle` mutates it → `ConcurrentModificationError` mid-download; buffered bytes lost, job crashes/resumes wrongly. Also proven by failing e2e test. | positional_file_writer.dart:320–337, 359–375 vs 181–194; call sites http_transfer_job.dart:824,839,868,1076,1131,1384 | Any download with ≥2 chunks when a periodic flush overlaps a first write of a new handle. |
| **C-2** | **Durable-save TOCTOU**: inside the save lock, `writer.flushAll()` fsyncs, but the serialized `state` is the *live mutable* TransferState — counters mutate during the await window, so saved offsets exceed durable disk bytes. Failure path additionally saves inflated state *after swallowing* the flush error. Under preallocation, reconcile can't catch it; incomplete chunks have no hash → zero-holes ship to final rename. | http_transfer_job.dart:2202–2223; download_journal.dart:614, 434–453; failure path :861–875 | Power loss mid-download → silently corrupt "complete" file. |
| **C-3** | **Unknown-size resume wipes ALL progress** when thread count changed: redistribution computes `nEnd = nc.start + nc.size` with `size == −1` → overlap 0 → `downloaded = 0`, journal already cleared → unrecoverable. | http_transfer_job.dart:391–422 (esp. :410); engines/http_download_engine.dart:64–66; download_journal.dart:318–322 | Pause an unknown-size download, change thread setting, resume → full re-download. |
| **C-4** | **ENOSPC swallowed at finalize**: `close()` catches generic exceptions after claiming "disk-full must not be swallowed", but `InsufficientStorageException` isn't a `PositionalFileWriterException` → warning-only → short/holey file marked complete. | positional_file_writer.dart:426–430 vs :262,:288,:292; engine_exceptions.dart:12–20 | Disk fills during final close-flush → corrupt completion. |
| **C-5** | **Scheduled downloads dead on Android**: Workmanager `callbackDispatcher` is an empty stub that ignores `'downloadScheduledTask'`; `ScheduleManager.start()` returns early without starting the in-app dynamic tick; scheduled check runs exactly once at provider load. | schedule_manager.dart:11–16, 96–115, 164–169; download_provider.dart:525 | User schedules download for +2h → never starts (foreground, background, or killed). |
| **C-6** | **Notification actions dead**: `NotificationCoordinator.init()` has no call site; Pause/Resume/Cancel/Install buttons and pending-action replay push events into a stream nobody listens to. | notification_coordinator.dart:159–167; notification_service.dart:142,163–190; grep-verified | All notification buttons do nothing. |
| **C-7** | **Wi-Fi-only / cellular-pause / auto-resume-on-reconnect dead**: `NetworkMonitor.init()` never called; connectivity-change pipeline fully orphaned. Compounded by **C-8**. | network_monitor.dart:96–114 (zero call sites), 149–339 | Mid-download disconnect pauses via engine errors only; "waiting for WiFi" tasks never resume automatically. |
| **C-8** | **Two live DownloadProvider instances + wrong IConnectivity binding**: DI registers a lazy factory separate from the UI-constructed provider; `IConnectivity` resolves the DI one whose connectivity set is always empty → every inferred pause misattributed as "network lost". | injection.dart:164–176; main.dart:257–262; torrent_download_handler.dart:331–345; network_monitor.dart:51–84 | Wrong pause reasons shown; duplicate state writers to same DB. |
| **C-9** | **Reader mode broken end-to-end**: menu extracts article + shows controls, but nothing ever renders it; `activateReaderMode`/`rebuildReaderHtml`/`closeReaderMode` have zero production callers. | browser_controller.dart:859–876; browser_menu_button.dart:378–381; reader_mode_service.dart:43–85 | Feature visibly does nothing. |

### P1 — High (leaks, security, wrong behavior in common flows)

| ID | Bug | Evidence |
|---|---|---|
| H-1 | BandwidthGovernor leaked on **every** single-stream pause/failure (constructor registers PowerMonitor listener; disposed only after loop; all exception exits skip it). Multi-thread path disposes correctly in `finally`. | http_transfer_job.dart:1588–1596 vs :2021–2023; exits at :1665,:1711,:1774,:1787,:1900–1921,:1950–1963,:1978–1979,:2013–2018 |
| H-2 | DioClientPool: cache-hit clients escape all accounting sets (invisible to eviction cap/memory pressure/metrics); `dispose()` closes only active clients → leaked HttpClients on teardown. | dio_client_pool.dart:222–240 vs :283–291 vs :384–401 |
| H-3 | `forceCancelJob` fails **every** pending job on the target worker, killing healthy sibling tasks (written to DB as failed). | download_isolate_pool.dart:507–574; http_download_orchestrator.dart:330–339 |
| H-4 | SSRF strict-mode bypass: `127.1`, `0x7f.1`, `0177.0.0.1` classified as hostnames (decoder handles only whole-number forms) → allowed; validation happens in `onResponse` **after** dart:io already connected+sent auth headers to the redirect hop. | ssrf_guard.dart:71,91–108; engine_utils.dart:119–144 |
| H-5 | Worker isolates see a blank SettingsProvider and frozen foreground state (statics are per-isolate; 'limits' message carries only bps/active) → `resumeIntegrityCheck`, stalled-timeout, background-cadence settings are inert on the real transfer path. | http_transfer_job.dart:59–103, 90–94, 799, 1601, 2179–2183; download_journal.dart:517–519,1092–1097 |
| H-6 | Torrent mixed lock domains (`_libtorrentLock` vs `_torrentLock`) over shared maps; add-registers fire-and-forget after returning id → immediate pause/remove races registration. | torrent_service_ffi.dart:37,39,130–143,413–455,704–712,843–851 |
| H-7 | `forceStopTorrent` swallows native stop failure after erasing all Dart-side traces (zombie upload continues invisibly). | torrent_service_ffi.dart:132–141 |
| H-8 | Magnet metadata timeout: placebo "retrying with additional trackers" loop calls native `addTracker` (no-op) — worst case ~15 min of sleeps reporting fake progress; also deletes partial files on timeout. | torrent_service_ffi.dart:794–808; libtorrent_native_impl.dart:467–469 |
| H-9 | Sequential-download flag: native setter no-op but service reports enabled → per-file progress estimator uses wrong distribution model. | torrent_service_ffi.dart:335,355–361; impl:485–487; torrent_download_handler.dart:2292,2307 |
| H-10 | `loadResumeData` caches blob before applying + returns true uninitialized → junk blobs persisted and reused. | torrent_service_ffi.dart:1054–1060; consumers main.dart:716 etc. |
| H-11 | `deleteFiles:true` honored only if handle alive — dead handle skips user-requested deletion silently. | torrent_service_ffi.dart:893–895 |
| H-12 | Expired-YouTube-URL fallback sorts **descending by distance** → picks farthest-quality stream. | youtube_service.dart:1099–1109 |
| H-13 | Autofill captures passwords as plaintext JS appended to per-host prefs (unbounded growth, never purged); fills them back; incognito-tab check reads the *global* toggle so incognito tabs persist form data. | browser_controller.dart:904–930; script_injector.dart:250–251,269–293; site_settings_store.dart:88–103 |
| H-14 | Incognito tabs share the global CookieManager/localStorage/cache while banner claims isolation; `signOut` calls `deleteAllCookies()` wiping every site's cookies. | browser_tab_view.dart:153–170; browser_screen.dart:498–500; browser_controller.dart:567–581; youtube_service.dart:126 |
| H-15 | HtmlSanitizer bypasses: entity-encoded `&#106;avascript:` survives; `/`-separated attributes survive event-handler stripper (`<div/onclick=…>`); `vbscript:` unhandled. Mitigated only by data:-URI origin (which is currently unreachable anyway, C-9). | html_sanitizer.dart:19–22,24–38,66 |
| H-16 | Backend client-side rate limiter throws synchronously at 30/min while bulk import resolves strictly sequentially with no pacing → pasting ~30+ links guarantees mid-batch failure; dismissing quality sheet aborts whole batch silently. | xdm_backend_client.dart:781–806; add_download_dialog.dart:1021–1064,990–993 |
| H-17 | Stale migration tests (Part 2) block CI green. | test/database_migration_test.dart; test/database_migration_v1_to_v27_test.dart |
| H-18 | `resetToDefaults()` omits ~15 keys (adaptiveThreads, thermalThreadLimiting, powerAwareIsolatePool, NAT-PMP/LPD/PEX/uTP/LSD, ipFilterPath, …) and doesn't re-sync `PowerMonitor` statics. | settings_provider.dart:1367–1437,1449–1521 |
| H-19 | HTTPS-only/proxy applied to main-isolate clients only when Network page opened (no app-startup seam) → after restart, browser/metadata-probe clients ignore policy until page visited. | network_settings_page.dart:59–63,79–123; dio_client_pool.dart:16–20 |
| H-20 | "Auto" category persists `''` → blank chip for LTR users, excluded from analytics donut/category grid entirely. | add_download_dialog.dart:1075; download_provider.dart:1143; download_filter_mixin.dart:136–155 |

### P2 — Medium

| ID | Bug | Evidence |
|---|---|---|
| M-1 | Storage analytics sums full `fileSize` of in-progress tasks ("Storage analytics" showing un-downloaded GB). | download_filter_mixin.dart:145–155; home_screen.dart:1321 |
| M-2 | Card telemetry strip uses video-only bytes vs combined bar for merged YouTube tasks → text contradicts bar. | download_orchestrator.dart:2098,2020–2034; download_card.dart:908–911; download_task.dart:559–572 |
| M-3 | Details speed chart labels index-based "Ns ago" assuming 1 Hz; HTTP ticks arrive faster; DL history capped at 20 vs UL 60 samples. | details_screen.dart:1878–1898; download_orchestrator.dart:2040–2044 |
| M-4 | Protocol badge shows "H1.1" when nothing measured (fabricated default); H3 has no producer. | download_card.dart:780–786 |
| M-5 | Torrent proxy credentials in plaintext SharedPreferences (token correctly in secure storage). | settings_provider.dart:700–701,396–404 |
| M-6 | Identity probe drains entire body when server ignores Range (hidden full-file re-download on every resume verify). | http_transfer_job.dart:584–621 |
| M-7 | Permanent-416 chunks recycle through scheduler until hard timeout (no terminal handling). | http_transfer_job.dart:2512–2531,1222–1234 |
| M-8 | Orchestrator writes `status:failed` for cancels (transient flapping, two-writer race on same row). | http_download_orchestrator.dart:330–343 |
| M-9 | `deleteTask` leaves `_lastDbSaveTimes/_lastDbSaveBytes/_retryTimers/_downloadMetrics/_tasksPausedDueToCharging` entries → slow map-growth leak. | download_provider.dart:1344–1391 |
| M-10 | Torrent card full-watches DownloadProvider (rebuilt every tick); details screen full-watches SettingsProvider ×4. | download_card.dart:2063; details_screen.dart:163,540,1261,2025 |
| M-11 | Dead parallel providers (`DownloadListProvider`, queue/filter/stats) registered + provided but zero consumers; ownership double-dispose hazard. | injection.dart:135–156; main.dart:510–517 |
| M-12 | Dual LRU bookkeeping (widget-mount vs eviction) can diverge → mounted WebView whose controller was disposed. | browser_tab_controller.dart:184–201 vs tab_manager.dart:115–141 |
| M-13 | Ad-block stealth layer (`injectAntiDetect/injectEarly/injectInto`) has zero call sites → popup-domain dynamic list always empty; early JS injected from onLoadStart (racy) instead of DOCUMENT_START user scripts. | ad_blocker_delegate.dart:83–127; ad_blocker_service.dart:720–731; browser_controller.dart:639–659 |
| M-14 | User-script "sandbox" freezes Object.prototype / replaces fetch/XHR/WebSocket with throwers globally → breaks matched pages' own JS; blacklist trivially bypassable. | user_script_manager.dart:253–395,74–197 |
| M-15 | Sniffed HLS/DASH/mp4 streams never reach quality sheet (`preloadedStreams` param unused; toolbar always sends page URL to backend). | media_quality_sheet.dart:14,69–77; browser_screen.dart:695–699; add_download_dialog.dart:770,988 |
| M-16 | Boot receiver only refreshes widget though manifest comments promise task restore. | AndroidManifest.xml:22,134–144; BootReceiver.kt:17–19 |
| M-17 | Screen-off journaling blackout unchanged (recordChunkProgress early-returns unless forced; <5 MB snapshot skip). | download_journal.dart:1090,554–556 |
| M-18 | Cancel-path `loadOrCreate` replays+clears journal against a live worker → worker may write to unlinked inode (POSIX), bounding recovery to last snapshot. | http_download_orchestrator.dart:274–284 |
| M-19 | A11y gaps: bare GestureDetectors on details actions, unlabeled step buttons/show-less toggles/batch bar, pie-filter touch-only. | details_screen.dart:1083–1150,1643–1654,3724–3745; download_card.dart:2596–2628; home_screen.dart:1190–1207,1367–1385 |
| M-20 | `PerformanceMonitor.healthSummary` hardcodes "60fps". | performance_monitor.dart:98–102 |
| M-21 | `nativeVersion` reports '2.1.1' while pubspec pins 1.9.2 (comment even says 2.0.0). | torrent_service_ffi.dart:1725–1727; pubspec.yaml:57 |

### P3 — Low / hygiene

- Dead code sweep: `estimateOptimalThreads`, `isLikelyHtmlResponse` (+2 duplicate HTML detectors), `CancellableDelayer`, `DelayQueueFullException`, `ChunkResult`, `cmd.adaptiveThreads` (never read), `AddDownloadViewModel`/`MediaQualityViewModel` (duplicated inline), `FingerprintManager.applyUserAgent/hideWebViewFingerprints`, `matchesPatternCached`, entire reader build/load chain, `tabGroupId`, `autoEnableSequentialForVideo`, `minSeedTimeMinutes` (no persistence key), `boostMagnetDiscovery{}`/`prioritizeFile{}` divergent impl bodies, `TorrentServiceImpl.getTorrentSnapshot/getRecentAlerts` constants.
- FIX-tag comment lies: "FIX 13: 50 KB/s baseline" not applied (http_transfer_job.dart:320,520 vs :528).
- `validateSavePath` swallows directory-create FileSystemException (download_engine.dart:591–593).
- Windows free-space probe spawns PowerShell per call and caches failures 30 s (download_engine.dart:131–206).
- Health indicator unreachable fallthrough + availability `?? 1.0` default leak (torrent_health_indicator.dart:31–38; details_screen.dart:2395–2400).
- Create-torrent latent fake-success `res != null || fileExists` if flag ever flipped (create_torrent_screen.dart:179).
- Bulk-import drops auth headers (add_download_dialog.dart:1071–1087); stale "35 seconds" error copy vs actual 45 s budget (youtube_service.dart:607–609 vs :721).
- Properties sheet fixed 120 px label column clips Arabic (download_card.dart:3637–3640).
- Sort-by-size ignores resolved size for pre-metadata magnets (download_filter_mixin.dart:207–208).
- `switchTab` fire-and-forget evaluateJavascript without catchError (browser_tab_controller.dart:52–55).
- `_evictStaleAdTabsInternal`/`clearAllTabs` don't dispose controllers (tab_manager.dart:350–373,314–325).

### Persisted-but-dead settings (implement or delete — Task from planx/05 still open)

`categoryFolders`, `cleanupDays`, `maxConcurrentFilesPerTorrent`, `maxActiveTorrents`, `useLocalYtFallback`, `pinchToZoom`, `openLinksInApp`, `formAutofill`, `translateTargetLang`, `developerMode` (neutered but advertised as SSL/logs).

---

## Part 4 — Master fix plan

### Phase 0 — Same-day wins (revive dead pipelines, get CI green) ≈ 1 day

| Step | Action | Acceptance |
|---|---|---|
| 0.1 | Call `_notifications.init()` (NotificationCoordinator) in DownloadProvider construction; wire pending-action replay. | Notification pause/resume/cancel/install buttons work; cold-start replay works. |
| 0.2 | Call `networkMonitor.init()` once after first connectivity resolution; bind `IConnectivity` to the UI provider's monitor (register the monitor itself as the singleton, inject into both). | Toggle wifiOnly mid-download → pauses; reconnect → auto-resumes; pause reasons correct for torrents. |
| 0.3 | Update both migration tests to v28 (parameterize expected version from `AppDatabase.schemaVersion`). | Full suite green. |
| 0.4 | Delete or finish the four dead parallel providers out of DI/tree (single source of truth). | No unreferenced ChangeNotifiers registered. |

### Phase 1 — Correctness & durability (the worst class of bugs) ≈ 3–5 days

| Step | Action | Acceptance |
|---|---|---|
| 1.1 | **Fix C-1**: take `_metaLock` around iteration in `flushAll`/`flushBuffers` (copy entries under lock, then flush copies); same pattern everywhere `_handles` is iterated unlocked. | Kill-mid-write fault-injection test (extend `test/e2e/download_resume_test.dart`) passes deterministically ×20. |
| 1.2 | **Fix C-2**: snapshot chunk counters (`Map<int,int>` copy) *before* `flushAll()`, serialize the snapshot, and refuse the save if snapshot bytes > flushed high-water mark; on flush failure skip the durable save entirely (keep in-memory). Add `flushedHighWaterBytes` to TransferState. | New unit test: concurrent mutation during save can never persist ahead-of-disk offsets. |
| 1.3 | **Fix C-3**: run `knownFileSize` fix-up *before* redistribution; treat indeterminate chunks (`end<0`) as unsplittable — carry `downloaded` verbatim into the new single chunk instead of overlap math. | Unit test: unknown-size 50 MB @ threads 1→16 keeps 50 MB. |
| 1.4 | **Fix C-4**: make `InsufficientStorageException` extend `PositionalFileWriterException` (or catch it explicitly in `close`); map ENOSPC at finalize to task status `failed(insufficientSpace)` with user-facing message. | Fault test: fill disk during close → task fails cleanly, partial preserved, no "completed". |
| 1.5 | **Fix C-5 scheduling**: implement the real `callbackDispatcher` handling `downloadScheduledTask` (promote queued task via method-channel into the foreground service), OR drop workmanager and drive ScheduleManager's in-app dynamic tick on Android + schedule exact alarms natively for killed-app case. | Integration test: schedule +2 min task with app backgrounded → starts within window. |
| 1.6 | **Fix C-9 reader mode**: render `controller.readerArticle` via the existing (already-sanitized) HTML in a dedicated route/sheet; hook font/theme strip controls to `rebuildReaderHtml`; wire exit/back to `closeReaderMode`; decode entities before scheme filtering in HtmlSanitizer; accept `/`-separator in attr regexes; add `vbscript:` to scheme blocklist. | Widget test: activate reader on sample article → rendered text visible; sanitizer unit tests for the 3 bypass vectors. |
| 1.7 | Terminal handling for permanent-416 chunks (M-7) and cancel-path journal clearing against live workers (M-18: quiesce worker or reopen journal before clear). | Matrix tests extended. |

### Phase 2 — Leaks, security, torrent correctness ≈ 4–6 days

| Step | Action |
|---|---|
| 2.1 | Dispose BandwidthGovernor in a `finally` on the single-stream path (H-1); add regression test asserting listener count stable across pause/resume cycles. |
| 2.2 | Re-account cache-hit clients into active sets on acquire; close idle+active on dispose (H-2). |
| 2.3 | `forceCancelJob`: deliver errors only to jobs matching taskId; requeue others (H-3). |
| 2.4 | SSRF: extend decoder to dotted-octal/short-form/mixed-radix literals; validate in `onRequest`/redirect callback *before* following (H-4); keep DNS-rebinding documented out-of-scope. |
| 2.5 | Pass settings snapshot (resumeIntegrityCheck, stalledTimeout, isBackground flag) inside job command/limits messages instead of relying on per-isolate SettingsProvider (H-5). |
| 2.6 | Torrent: unify onto one `Lock` (H-6); propagate stop failures (H-7); gate placebo tracker-retry message behind `trackersSupported` and cap total metadata wait (H-8); stop reporting sequentialDownloadEnabled when unsupported and stop feeding estimator with it (H-9); make `loadResumeData` cache only after successful apply (H-10); honor deleteFiles for dead handles via best-effort re-add+remove or explicit warning (H-11). |
| 2.7 | Secrets: migrate proxy password → secure storage (M-5); purge autofill store, exclude incognito tabs properly, gate capture behind existing `formAutofill` toggle (then actually implement its consumer) (H-13). |
| 2.8 | Incognito: use `ShouldOverrideUrlLoading`+incognito `CookieManager`/shared `WebViewEnvironment` isolated store where supported; fix banner copy to match reality if full isolation ships later; scope `signOut` cookie deletion to google/youtube domains (H-14). |
| 2.9 | Rate limiter: make bulk import respect pacing (await permit asynchronously) + surface per-item results; keep headers through batch path; fix dismiss-abort feedback (H-16). |
| 2.10 | Fix expired-URL comparator (`distA - distB`) + golden test (H-12). |

### Phase 3 — Settings truthfulness & UI honesty ≈ 3–4 days

| Step | Action |
|---|---|
| 3.1 | Startup seam: apply `DioNetworkPolicy.update(...)` (httpsOnly/proxy) right after `SettingsProvider.load()` in bootstrap (H-19). |
| 3.2 | Complete `resetToDefaults()`: derive removal list from the keys registry (single source), re-sync PowerMonitor statics after reset (H-18). |
| 3.3 | Implement-or-delete each dead toggle (list above). Recommended: implement `categoryFolders` (move-on-complete already exists per-category), `cleanupDays` (log-rotation job), `maxConcurrentFilesPerTorrent`/`maxActiveTorrents` (feed queue mixin), delete the rest including misleading `developerMode` copy. |
| 3.4 | Category "Auto" → infer via `categoryFromFileName` fallback; backfill '' categories on migration (H-20). |
| 3.5 | UI honesty: storage analytics uses on-disk bytes (or relabel); card telemetry uses `displayDownloadedBytes`; chart axis derived from sample timestamps; protocol badge shows "—" until measured; healthSummary reports measured fps (M-1..M-4, M-20). |
| 3.6 | A11y pass: add Semantics(button)+labels to listed GestureDetectors; alternative access to pie-filter (M-19). |

### Phase 4 — Feature maximization (parity → differentiation) ≈ 2–4 weeks

Ranked by leverage:

1. **Torrent Track A — restore native capabilities** (single biggest gap): upgrade `libtorrent_flutter` pin to a symbol-complete build (CI ELF-symbol validation tool already exists in repo history), enable fast-resume (kills full recheck on restart), trackers, per-file progress, sequential streaming, create-torrent (fix latent fake-success first), web seeds, IP filter. Each capability flag flips UI panels on automatically thanks to the gating layer already shipped. *Depends on native binary availability — see planx/02 §Track A.*
2. **De-risk media extraction SPOF**: ship an on-device fallback extractor (yt-dlp via ffmpeg-kit's bundled binaries is not viable → consider a lightweight in-app innertube client for YouTube basics + keep backend for long-tail sites), honoring the already-present-but-unwired `useLocalYtFallback` toggle.
3. **Sniffer delivery**: pass `detectedStreams` into `MediaQualitySheet.preloadedStreams` from toolbar + dialog paths so sniffed HLS/DASH/mp4 downloads directly without backend (M-15) — turns the sniffer from 5/10 into a headline feature offline.
4. **Link grabber UI**: page-wide link extraction feeding existing `DownloadInterceptor.interceptBatch`.
5. **Incognito done right + Tab groups**: isolated WebViewEnvironment per incognito profile, group color tags using the dormant `tabGroupId` field.
6. **Ad-block polish**: wire the anti-detect/early-injection trio as DOCUMENT_START UserScripts; move Google whitelist to per-YT-page only; raise scriptlet coverage beyond 8 types.
7. **Custom categories** with editable rules (extension/filename/regex) replacing the six hardcoded ones.
8. **Localization completion** + RTL fixes (properties sheet column), accessibility audit to zero unlabeled controls.
9. **Desktop enablement** rides on the engine already being isolate-based: tray/window_manager deps exist; finish Windows shell integration (context menu, protocol handler).
10. **Boot restore**: actually restart the foreground service on BOOT_COMPLETED when `autoStartOnBoot` is enabled (currently widget-only, M-16).

### Definition of done (global acceptance bar)

- Zero failing tests; new fault-injection matrix covers: kill/power-loss mid-write, ENOSPC at every phase, unknown-size resume across thread changes, forced cancel with sibling tasks.
- No displayed metric without a live source (grep-audited quarterly via the truthfulness test pattern).
- Every shipped toggle has a verified consumer (add the "dead settings" enumeration guard test from planx/05 Task 5.8).
- Leak regression suite: governor/Dio-client/controller counts stable across 100 pause-resume cycles.
