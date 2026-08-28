# Plan 06 — Feature Parity & UX Polish

**Priority: P2** (reach table-stakes parity + differentiation; do after correctness/honesty plans)
**Current score: 8.0/10 → target 9.5+/10**

DMX is genuinely built-out and polished — **zero "coming soon" stubs** in `lib/`. It already **exceeds** typical mobile competitors on: embedded browser depth (tabs/bookmarks/reader/PiP/find), **real ad-block** (EasyList/EasyPrivacy/AdGuard + scriptlets + native content blockers + anti-adblock defeat), sandboxed **user scripts**, torrent **creation**, accessibility infrastructure, and theming (light/dark/AMOLED). It matches on scheduler, queue, speed-limit, clipboard monitor, and batch add.

The gap to 9.5 is: one **single-point-of-failure** (remote media extraction), a few **table-stakes DM features missing** (HTTP auth/headers, HTTP proxy, custom categories, link grabber), and **localization inconsistency**.

## Verified findings (evidence)

| ID | Sev | Finding | Evidence |
|---|---|---|---|
| U1 | HIGH | **Media extraction is 100% remote-backend-dependent.** All YouTube/social extraction funnels to one Google Cloud Run server; hard-fails if disabled/down. No on-device extractor. If the origin dies, every user loses a headline feature. | `youtube_service.dart:580,681`; `xdm_backend_client.dart:672-673`; `constants.dart:21` |
| U2 | HIGH | **No HTTP auth / custom headers per download.** Only `referrer` + global UA. Blocks authenticated/CDN-token/enterprise downloads competitors support. | `add_download_view_model.dart` (only `referrer`); `add_download_dialog.dart:659` |
| U3 | MED | **HTTP proxy missing for regular downloads** — proxy exists but is **torrent-only**. | `torrent_advanced_settings_sheet.dart:35-61`; no proxy in `network_settings_page.dart` or HTTP engine |
| U4 | MED | **Categories are a fixed hardcoded set** (Video/Audio/Document/Archive/APK/Other); no user-defined categories, rules, or per-category folders. Plus a naming bug: `resolveCategory` emits `Software`/`Image` and the interceptor emits `Executable`/`Torrent`, none of which have a card → miscounted/invisible. | `categories_screen.dart:33-70`; `site_intelligence_service.dart:621,625`; `download_interceptor.dart:388-396` |
| U5 | MED | **No page-wide link grabber** (grab all downloadable links). Only per-media sniff + paste. Infra to feed it exists (`interceptBatch`). | `download_interceptor.dart:439` |
| U6 | MED | **Localization inconsistent.** `MaterialApp` sets `locale` but **no `localizationsDelegates`/`supportedLocales`** → system widgets stay English, no formal RTL. Many screens hardcode `isRtl ? 'ar':'en'` ternaries → es/fr/de silently English on those strings. | `main.dart:527-535`; `categories_screen.dart:134`; `history_screen.dart:476` |
| U7 | LOW | Clipboard monitor **off by default**; remote-control API off with no companion UI. | `clipboard_service.dart:101`; `remote_api_service.dart:97` |
| U8 | LOW | No in-app preview (video/image/PDF open externally). | `file_opener.dart` |
| U9 | LOW | No time-of-day **speed scheduler** (only start-time scheduling). Infra exists (`bandwidth_governor` + `schedule_manager`). | — |

## Tasks (by leverage)

### Task 6.1 — De-risk media extraction (U1) — highest impact
The app's most-used feature must not die with one server.
- **Minimum:** a prominent, graceful degraded mode — detect backend unavailability (circuit breaker already exists, `youtube_service.dart:674`) and show a clear, actionable message instead of a silent failure. Cache last-known formats where possible.
- **Better:** add an on-device fallback extractor (bundled/embeddable) for at least the top sites, so a dead Cloud Run doesn't zero-out downloads. This is what 1DM/ADM do.
- **Operationally:** make the backend URL + key configurable/self-hostable (partly there via `--dart-define DMX_API_KEY` and `backendUrl` setting) and document self-hosting so the feature isn't hostage to one funded instance.

### Task 6.2 — HTTP auth + custom headers per download (U2)
- Add username/password (Basic/Digest) and an arbitrary header key/value list to `AddDownloadViewModel` + the add dialog, persisted on the task and applied by the HTTP engine (alongside the existing `referrer`/UA path). Unlocks authenticated/enterprise/CDN downloads.

### Task 6.3 — HTTP/SOCKS proxy for regular downloads (U3)
- Reuse the existing proxy settings (`proxyType/Host/Port/user/pass`) — extend beyond torrents to the HTTP engine (`dio_client_pool`/transfer Dio) and expose in `network_settings_page.dart`. Coordinate with the SSRF/redirect guard (Plan 01 Task 1.10).

### Task 6.4 — Custom categories with rules + folders (U4)
- Make categories data-driven: user-defined name + extension/host rules → target folder. Replace the hardcoded 6 (`categories_screen.dart:33-70`).
- Reconcile category names end-to-end so `Software`/`Image`/`Executable`/`Torrent` are either mapped to displayed categories or given cards — fix the miscount/invisibility bug.
- Wire `categoryFolders`/`customDownloadPath` so files actually land in per-category folders (ties to Plan 05 Task 5.6).

### Task 6.5 — Page-wide link grabber (U5)
- Add "grab all downloadable links" to the browser (extend `media_sniffer`/`element_picker_service`) → a selection sheet → `download_interceptor.interceptBatch` (`:439`, already exists). Big win for bulk users; most infra is present.

### Task 6.6 — Localization consistency (U6)
- Register `localizationsDelegates` + `supportedLocales` on `MaterialApp` (`main.dart:527`) so system widgets localize and RTL is formal.
- Replace inline `isRtl ? 'ar':'en'` ternaries (e.g. `categories_screen.dart:134`, `history_screen.dart:476`) with `L10n` keys so es/fr/de aren't silently English.
- Audit the 5 language files for missing keys.

### Task 6.7 — Turn on latent power features (U7)
- Enable clipboard monitoring by default with a clear toggle + a non-intrusive "detected a link — download?" prompt (`clipboard_service.dart:101`).
- Either ship a minimal companion/web UI for the remote-control API or hide/document it (`remote_api_service.dart:97`).

### Task 6.8 — Speed scheduler + in-app preview (U9, U8)
- Time-of-day bandwidth profiles on top of `bandwidth_governor` + `schedule_manager` (depends on Plan 05 Task 5.1 global-limit wiring).
- Lightweight in-app preview for completed video/image/PDF.

### Task 6.9 — Accessibility coverage pass
- `Semantics` infra is solid but coverage is partial (~36 spots). Extend `semanticLabel`/`XdmSemantics` to all interactive widgets (the `ACCESSIBILITY.md` intent, which is currently aspirational per memory).

## Acceptance criteria (9.5 bar)

- A dead extraction backend produces a clear degraded UX (or on-device fallback), never a silent zero.
- Authenticated downloads (Basic/Digest + custom headers) and HTTP/SOCKS-proxied downloads work.
- Users can define categories with rules + target folders; every auto-assigned category is visible and counted correctly.
- Link grabber pulls all downloadable links from a page into a batch add.
- es/fr/de users see translated strings everywhere; system widgets localize; RTL is correct.

## Test plan

1. Backend-down test: circuit-open state → assert graceful message / fallback, not a crash or blank (6.1).
2. Auth download test against a Basic-auth-protected URL (6.2).
3. Proxy download test through a local SOCKS proxy (6.3).
4. Category rule test: define a rule → downloaded file lands in the right folder + category (6.4).
5. Link-grabber test on a fixture page with multiple media links (6.5).
6. Locale test: switch to `de` → assert a known screen string is German and a date picker localizes (6.6).

## Effort / risk

- 6.1 is the big one — on-device extraction is significant (~1–2 wks); the graceful-degrade minimum is ~1–2 days. Do the minimum first.
- 6.2/6.3/6.4/6.5: ~2–3 days each, low/medium risk (mostly additive; infra largely present).
- 6.6/6.7/6.8/6.9: ~1–3 days each, low risk.
