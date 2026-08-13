# ⚡ XDM // XTREME DOWNLOAD MANAGER

<p align="center">
  <img src="assets/app_icon/icon.png" width="128" height="128" alt="XDM Icon" style="border-radius: 28%;" />
</p>

<p align="center">
  <strong>A premium, multi-threaded Flutter download manager, BitTorrent client & full-featured Web Browser — with a built-in media sniffer, YouTube extraction, custom script injection, torrent seeding, and a high-performance isolate download engine.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white&style=for-the-badge" alt="Flutter" />
  <img src="https://img.shields.io/badge/Dart-3.0+-0175C2?logo=dart&logoColor=white&style=for-the-badge" alt="Dart" />
  <img src="https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Windows%20%7C%20macOS%20%7C%20Linux%20%7C%20Web-000000?style=for-the-badge" alt="Platforms" />
  <img src="https://img.shields.io/badge/Version-3.0.0-blue?style=for-the-badge" alt="Version" />
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License" />
</p>

---

## ✨ Features

### 🚀 High-Performance Download Engine
- **Background Isolate Architecture**: All heavy HTTP networking, segmented file streaming, and File I/O run inside a pooled `DownloadIsolatePool` of background workers — zero UI stutter during high-speed multi-threaded downloads.
- **Multi-Segment Parallel Downloads**: Configurable concurrency of 1–16 parallel streams per file with an adaptive single-stream fallback for servers that don't support ranges.
- **Network Resilience & Auto-Resume**: Live network listening (`connectivity_plus`) with auto-pause on connection loss, surgical resume on reconnection, and orphaned-task recovery on app launch when `autoStart` is enabled.
- **HTTP/2 & HTTP/3 (QUIC)**: `ConnectionManager` probes hosts and negotiates the best protocol — `cronet_http` on Android, `cupertino_http` on iOS.
- **Per-Domain Speed Limiting**: `BandwidthGovernor` with a token-bucket governor, global MB/s sliders, and scheduled (time-window) speed limits that kick in automatically.
- **Journal Integrity & Recovery**: Append-only CRC32-wrapped `.journal` files plus a `resumeIntegrityCheck` that spot-checks 64KB samples before resuming, auto-deleting corrupted chunks.
- **Mirror Failover & Health**: Multi-mirror URLs with benchmarked mirror selection, health persistence, circuit breakers, and automatic failover.
- **Retry & Backoff**: Configurable auto-retry (1–10 attempts) with adjustable delays and exponential backoff.
- **Checksum Verification**: Optional SHA-256 auto-verification against expected hashes on completion.
- **FFmpeg Muxing**: Separately downloaded video + audio streams (YouTube 720p+) are multiplexed in-app via `ffmpeg_kit`.
- **Disk Space & I/O Smartness**: Disk-space guardrails, low-storage warnings, batched 256KB disk writes, cross-filesystem copy-based relocation, and orphan-file cleanup on cancel.

### 🧲 BitTorrent Client
- **Full Torrent & Magnet Support**: BitTorrent v1/v2 magnet links, `.torrent` files, retryable magnet metadata resolution with progress callbacks, and in-app **torrent creation** (`.dat`/`.torrent`).
- **DHT & Peer Discovery**: Integrated DHT bootstrap node injection (`router.bittorrent.com:6881`, etc.), UPnP, NAT-PMP, LPD, and PEX with forced protocol encryption.
- **Tracker & Peer Management**: Live tracker health scoring, quick "Add Default Trackers" action (10 open UDP trackers), auto-reannounce, and peer connection quality, encryption lock, and direction indicators.
- **Dual-Speed Charting & Health Indicator**: Dual download & upload speed history charting in the transfer speed graph, alongside granular health evaluations (Dead, Poor, Fair, Good, Excellent).
- **Seeding Management & Smart Guardrails**: Global seeding toggle, upload speed caps, share-ratio limits, max seeding time, super seeding, charging-only mode (`seedOnlyWhenCharging`), and Wi-Fi-only mode (`seedOnlyOnWifi`).
- **Disk-Verified Per-File Progress**: Disk-level content probing to handle pre-allocated zero-fill files cleanly.
- **Torrent Creation**: Flexible piece size selection (Auto, 256KB to 8MB), Web Seeds URL input, source tagging, comment embedding, and private torrent toggles.

### 🌐 Smart Built-in Web Browser
- **Multi-Tab & Tab Groups Engine**: Tab strip, visual tab switcher, tab group organization (color-coded grouping, moving, closing), persistent scroll-position tab suspension, recently-closed tab restoration, and background tab memory management.
- **Incognito Mode**: Isolated sessions with cookie/storage purge on tab close and purple incognito indicators.
- **Smart Force Dark Mode**: High-contrast dark styling engine with media-preservation filters for `img/video/canvas/svg` plus native Android `ForceDark` rendering.
- **Ad-Blocker & Dynamic Content Guard**: High-performance ad blocking with MutationObserver dynamic ad element removal, compiled regex cache, fast-path $O(1)$ domain lookups, custom host store, and redirect protection.
- **Privacy Dashboard**: Real-time stats dashboard tracking blocked trackers, ads, and popups per domain and overall totals.
- **Advanced Media Sniffer**: Automatic detection of video/audio/direct links, HLS (`.m3u8`) and DASH (`.mpd`) streaming manifests, blob sources, and network performance resource inspection with batch download quality sheets.
- **Debounced Download Interception**: Intelligently intercepts binary files and stream downloads with rapid-click debouncing, batch enqueuing, priority queue integration, and multi-source download sheets.
- **Reader Mode v2**: Intelligent Readability-style article extraction capturing title, author, published date, clean HTML content, text preview, images, word count, and estimated reading time across light/dark/sepia themes.
- **Smart URL Bar & Security Indicators**: Dynamic address bar displaying `UrlSecurityLevel` badges (HTTPS secure, HTTP insecure, dangerous, unknown), active download badges, and instant URL/bookmark/history suggestions.
- **UserScript / CSS Injector**: Custom script manager with granular permission sandboxing and a live JS/CSS editor.
- **Desktop Keyboard Shortcuts**: Complete desktop hotkey suite (`Ctrl+T` new tab, `Ctrl+W` close tab, `Ctrl+R` reload, `Ctrl+L` address bar, `Ctrl+D` bookmark, `Ctrl+H` history, `Alt+Left/Right` navigation).
- **Picture-in-Picture & Capture Tools**: Native HTML5 Picture-in-Picture mode for HTML5 video, single-viewport capture, and full-page stitched screenshot export.
- **Browser Extensions**: Companion extensions for **Firefox Android** (`xdm-firefox/`) redirect browser downloads to XDM.

### 📺 YouTube & Cloud Stream Integration
- **XDM Cloud Backend**: Remote FastAPI / yt-dlp backend (configurable URL + secure token) for YouTube metadata and stream extraction.
- **Quality & Playlist Selection**: Single videos, playlists, and shorts; format/quality sheet (up to 4K) with muxed, combined, audio-only, and video-only sections; batch-enqueue playlists.
- **Auto-Retry & Expiration Refresh**: Automatically detects `403/410` link expirations and refetches fresh stream manifests.
- **Account Features**: Optional browser-cookie OAuth sign-in for age-restricted/private media, with local yt-dlp fallback support.

### 🔐 Security & Privacy
- **App Lock (PIN)**: Passcode startup lock with failed-attempt lockout timer.
- **Secure Storage**: Backend tokens and proxy secrets stored in platform keychains via `flutter_secure_storage`.
- **Anti-Fingerprinting**: Obscures `navigator.webdriver` and WebView automation signatures to defeat bot detection.
- **Optional HTTPS-only mode** and developer-gated SSL-bypass with confirmation.
- **AES-256 Encrypted Backups**: Export/import settings + bookmarks backups protected with derived passwords.

### 🎨 Design System & Cockpit UI ("Signal Deck")
- **Futuristic Aesthetic**: Glassmorphism, backdrop filters, animated geometric grid backgrounds, neon glow effects, and tactile haptic feedback.
- **Quad-Theme Engine**: **Light**, **Dark**, **AMOLED Pure Black**, and **Follow System** modes, plus a Classic UI toggle and battery-saver forced classic mode.
- **Responsive Layout**: Floating **Bottom Navigation Bar** on phones, a floating pill bar on tablets, and a **Navigation Rail** on desktop/large displays with cross-fade tab switching.
- **5 Locales with full RTL**: English, العربية, Deutsch, Español, Français.

### 🔌 Platform Ecosystem
- **iOS**: Native `URLSession` background downloads, WidgetKit home-screen widgets (App Group), Share Extension, Live Activities (Dynamic Island & Lock Screen), and Siri/Shortcuts App Intents.
- **Android**: Foreground background service with wake lock, persistent notification actions, and media widgets data bridge.
- **Desktop** (Windows/macOS/Linux): System tray, in-app update manager with code-signature + SHA-256 verification, **single-instance port guard**, and a local authenticated **remote-control HTTP API** (`RemoteApiService`).
- **Deep Linking & Share**: `dmx://` deep links, inbox clipboard URL detection, and share-intent URL handling.
- **Diagnostics**: Sentry crash reporting (opt-in via `SENTRY_DSN`), frame-watchdog jank detection with auto battery-saver, power/thermal-aware throttling, and quiet hours.

---

## 🛠️ Tech Stack

| Layer | Technology |
|-------|-----------|
| **Framework** | Flutter / Dart ^3.0.0 |
| **State Management** | Provider + get_it |
| **Local Database** | drift (SQLite) + Hive + SharedPreferences + flutter_secure_storage |
| **Networking** | Dio ^5.11.0 + cronet_http + cupertino_http |
| **Download Engine** | Custom isolates + positional file writer + CRC32 journal |
| **BitTorrent** | libtorrent_flutter (DHT/UPnP/NAT-PMP/LPD/PEX) |
| **YouTube Backend** | XDM Cloud Run Service (FastAPI / yt-dlp) + local fallback |
| **Web Engine** | flutter_inappwebview |
| **Media** | ffmpeg_kit_flutter + open_filex + share_plus |
| **Background / Notifications** | flutter_background_service + flutter_local_notifications (+ iOS Live Activities / WidgetKit) |
| **Security** | flutter_secure_storage + pointycastle / encrypt (AES-256) |
| **Observability** | sentry_flutter + performance_monitor + frame_watchdog |
| **UI** | custom design system with Space Grotesk + Inter, fl_chart, font_awesome_flutter |

---

## 📁 Project Structure

```
lib/
├── core/
│   ├── app_theme.dart               # "Signal Deck" design tokens, motion, & 3 theme builders
│   ├── di/                          # Service locator
│   ├── models/                      # Shared data models (backend models, etc.)
│   ├── services/                    # 60+ services: engine, isolates, torrent, mirrors,
│   │                                #   backend, youtube, notifications, security, lifecycle
│   └── utils/                       # L10n (5 locales), URL/magnet parsing, haptics, crypto, bencode
├── features/
│   ├── add_download/                # Add dialog, media quality sheet, YouTube playlist sheet
│   ├── browser/                     # Browser screen, tab manager, sniffer, adblock, script manager
│   ├── categories/                  # Category breakdown + detail drill-down
│   ├── details/                     # Per-task details: speed graph, chunks, torrent panels
│   ├── downloads/                   # Provider (orchestrator + 4 mixins), task model, cards, stats
│   ├── history/                     # Completed / failed download history
│   ├── home/                        # Dashboard: analytics, stats, filter chips, segmented tabs
│   ├── onboarding/                  # First-run walkthrough + Android download-folder gate
│   ├── settings/                    # 7 paginated sections: Appearance, Downloads, Network,
│   │                                #   Notifications, Power, Torrent, Advanced
│   └── torrent_create/              # Create .torrent metadata files
└── shared/
    ├── accessibility/               # Text scaling, focus traversal, semantics, announcer, motion
    ├── design/                      # dmx_design.dart component library (DmxCard, DmxButton, …)
    ├── mixins/                      # Pausable loop animation
    └── widgets/                     # MainNavigationContainer, GeometricGrid, GlassCard, etc.
```

---

## 🚀 Getting Started

### Prerequisites
- Flutter SDK (Dart `>= 3.0.0`), Android SDK (min API 21+), Xcode 15+ (iOS), or Windows 10+ / macOS / Linux.

### Installation
```bash
git clone https://github.com/DevEslam1/XDM.git
cd XDM
flutter pub get
flutter run
```

### Optional Build Flags
- `--dart-define=DMX_API_KEY=...` — compile-time backend API key (falls back to bundled default).
- `--dart-define=SENTRY_DSN=...` — enable Sentry crash reporting.

---

## 📄 Documentation

- [design.md](design.md) — full design system: tokens, typography, motion curves, component library, and UI architecture.
- [docs/ACCESSIBILITY.md](docs/ACCESSIBILITY.md)
- [docs/DOWNLOAD_ENGINE.md](docs/DOWNLOAD_ENGINE.md)
- [docs/TORRENT_SUPPORT.md](docs/TORRENT_SUPPORT.md)
- [docs/IOS_PLATFORM.md](docs/IOS_PLATFORM.md)
- [docs/IOS_TORRENT_BACKGROUND.md](docs/IOS_TORRENT_BACKGROUND.md)

---

## 📄 License

MIT License — see [LICENSE](LICENSE).

---

## 👨‍💻 Developer

**Eslam Mahmoud** — Mobile Development Engineer

- Email: xdev.eslam@gmail.com
- GitHub: [github.com/DevEslam1](https://github.com/DevEslam1)
- LinkedIn: [linkedin.com/in/deveslam-mahmoud](https://linkedin.com/in/deveslam-mahmoud)