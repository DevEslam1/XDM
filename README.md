<p align="center">
  <a href="https://deveslam1.github.io/XDM/">
    <img src="assets/app_icon/icon.png" width="120" height="120" alt="XDM Logo" style="border-radius: 28px; box-shadow: 0 10px 30px rgba(59, 130, 246, 0.3);" />
  </a>
</p>

<h1 align="center">⚡ XDM — Extreme Download Manager</h1>

<p align="center">
  <strong>A high-velocity, multi-threaded Flutter download engine, full BitTorrent client, and media-sniffing web browser.</strong>
</p>

<p align="center">
  <a href="https://deveslam1.github.io/XDM/"><img src="https://img.shields.io/badge/Website-Live_Landing_Page-00C4CC?style=for-the-badge&logo=googlechrome&logoColor=white" alt="Live Website" /></a>
  <a href="https://github.com/DevEslam1/XDM/releases/latest"><img src="https://img.shields.io/badge/Android_Release-v3.0.0_Stable-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Android Release" /></a>
  <a href="https://github.com/DevEslam1/XDM/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-MIT-3B82F6?style=for-the-badge&logo=opensourceinitiative&logoColor=white" alt="MIT License" /></a>
  <a href="https://flutter.dev"><img src="https://img.shields.io/badge/Flutter-3.x_Dart_3.0+-02569B?style=for-the-badge&logo=flutter&logoColor=white" alt="Flutter" /></a>
</p>

<p align="center">
  <a href="#-quick-download">Download APK</a> •
  <a href="#-key-features">Key Features</a> •
  <a href="#-platform-availability">Platform Matrix</a> •
  <a href="#-architecture">Architecture</a> •
  <a href="#-getting-started">Getting Started</a> •
  <a href="#-tech-stack">Tech Stack</a> •
  <a href="#-documentation">Docs</a>
</p>

---

## ⚡ Overview

**XDM (Extreme Download Manager)** is a next-generation, open-source download workstation built from the ground up with **Flutter and Dart**. It delivers up to **16× accelerated downloads** through background isolate pooling, features a full **BitTorrent & DHT client**, and includes a **smart web browser** with media sniffing, dynamic ad-blocking, YouTube 4K stream muxing, and a futuristic "Signal Deck" cockpit UI.

> [!TIP]
> 📱 **Current Release Status:** **XDM is currently available as a full stable release for Android (8.0+)**. Native ports for Windows, macOS, Linux, and iOS are in active development.

---

## 📥 Quick Download

| Platform | Channel | Build Status | Link |
| :--- | :--- | :--- | :--- |
| **Android** | Stable (Direct APK) | <img src="https://img.shields.io/badge/Available-3DDC84?style=flat-square&logo=android&logoColor=white" /> | [**Download APK (v3.0)**](https://github.com/DevEslam1/XDM/releases/latest) |
| **Android** | Companion Extension | <img src="https://img.shields.io/badge/Ready-FF7139?style=flat-square&logo=firefox&logoColor=white" /> | [**Firefox Android Addon**](xdm-firefox/) |
| **Windows** | Desktop (x64) | <img src="https://img.shields.io/badge/Roadmap-0078D4?style=flat-square&logo=windows&logoColor=white" /> | *In Development (Flutter Desktop)* |
| **macOS** | Universal DMG | <img src="https://img.shields.io/badge/Roadmap-999999?style=flat-square&logo=apple&logoColor=white" /> | *In Development* |
| **Linux** | AppImage / .deb / Flatpak | <img src="https://img.shields.io/badge/Roadmap-FCC624?style=flat-square&logo=linux&logoColor=black" /> | *In Development* |
| **iOS** | TestFlight / Sideload IPA | <img src="https://img.shields.io/badge/Roadmap-000000?style=flat-square&logo=apple&logoColor=white" /> | *In Preparation* |

---

## ✨ Key Features

### 🚀 1. High-Performance Isolate Download Engine
* **Threaded Isolate Pool (`DownloadIsolatePool`)**: All segmented chunk downloads, HTTP socket multiplexing, and direct disk streaming run off the main UI thread with zero frame drops.
* **16-Segment Adaptive Streams**: Splits large files into up to 16 parallel chunks with dynamic single-stream fallback when remote servers reject range requests.
* **Append-Only CRC32 Journal Recovery**: Crash-proof `.journal` transaction logs. On unexpected app exit or network drop, XDM checks chunk boundaries without redownloading finished bytes.
* **Bandwidth Governor**: Token-bucket speed throttle with global MB/s limits, per-domain quotas, and scheduled time-window speed profiles.
* **Automatic Mirror Failover**: Benchmark multiple mirror URLs and seamlessly switch endpoints if a server drops or returns error codes.
* **HTTP/2 & HTTP/3 (QUIC) Engine**: Negotiates ultra-fast modern protocols with host connection probing (`cronet_http` on Android).

### 🧲 2. Native BitTorrent & DHT Client
* **Magnet & Torrent Files**: Supports BitTorrent v1 and v2 protocols with instant magnet metadata resolution.
* **Decentralized DHT & PEX**: Integrated DHT bootstrap node injection (`router.bittorrent.com:6881`), UPnP, NAT-PMP, Local Peer Discovery (LPD), and peer exchange with mandatory stream encryption.
* **Sequential Torrent Streaming**: Play media files sequentially while the torrent actively downloads.
* **Smart Power Guard**: Automatically pauses seeding when battery level is low or charging is disconnected (`seedOnlyWhenCharging`, `seedOnlyOnWifi`).
* **In-App Torrent Creator**: Create custom `.torrent` files with piece sizes from 256KB to 8MB and custom tracker tiers.

### 🌐 3. Built-in Smart Browser & Media Sniffer
* **Automatic Media Sniffer**: Real-time detection of MP4, WebM, audio streams, HLS (`.m3u8`) and DASH (`.mpd`) video manifests across 200+ media sites.
* **Dynamic Ad-Blocker & Privacy Shield**: $O(1)$ fast-path domain blocker with MutationObserver ad element elimination and anti-redirect protection.
* **Reader Mode v2**: Distraction-free article parsing with typography scaling, estimated read times, and light/dark/sepia themes.
* **Tab Groups & Incognito**: Isolated cookie sessions, visual tab switcher, tab suspension for background RAM saving, and tab group color tags.
* **Force Dark Mode**: High-contrast dark rendering that preserves native media elements (`img`, `video`, `svg`, `canvas`).
* **UserScript & Custom CSS**: Built-in editor to execute custom JavaScript/CSS per domain.

### 📺 4. YouTube 4K & Cloud Stream Extraction
* **Cloud & Local yt-dlp Backend**: Remote FastAPI backend integration for instant metadata parsing.
* **4K & High-Bitrate Audio Muxing**: Downloads separate high-res video and audio tracks, then multiplexes them via `ffmpeg_kit` into a single lossless MKV/MP4 file.
* **Auto Expiration Refresh**: Automatically detects expired `403/410` CDN links and requests fresh signed URLs.

### 🎨 5. "Signal Deck" Cockpit UI & Themes
* **5 Immersive Themes**: **Cyber Blue**, **AMOLED Pure Black**, **Emerald Matrix**, **Aurora Violet**, and **Light Deck**.
* **Live Speed Sparklines**: Real-time upload/download charts, segment chunk visualizer, and diagnostic metrics.
* **Full RTL & Multilingual**: Supports English, العربية, Deutsch, Español, and Français.

---

## 🏛️ Architecture & Project Structure

```
XDM/
├── lib/
│   ├── core/
│   │   ├── app_theme.dart               # Signal Deck tokens, themes, & styling
│   │   ├── di/                          # get_it service registration
│   │   ├── models/                      # Shared entity models & DTOs
│   │   ├── services/                    # 60+ modular services:
│   │   │   ├── download_engine.dart     # Isolate pool, chunk management
│   │   │   ├── bandwidth_governor.dart  # Token bucket rate limiting
│   │   │   ├── torrent_service.dart     # Libtorrent bindings & DHT
│   │   │   ├── media_sniffer.dart       # Network inspection & sniffer
│   │   │   └── ffmpeg_service.dart      # Video/audio multiplexing
│   │   └── utils/                       # L10n, URL & magnet parsers, CRC32
│   ├── features/
│   │   ├── add_download/                # Add download dialog & YouTube sheets
│   │   ├── browser/                     # Multi-tab browser, adblock, sniffer
│   │   ├── categories/                  # File categorization & filters
│   │   ├── details/                     # Per-task chunk inspection & speed graph
│   │   ├── downloads/                   # Main downloads orchestrator & state
│   │   ├── history/                     # Completed transfer history
│   │   ├── home/                        # Cockpit dashboard & analytics
│   │   ├── settings/                    # Modular settings (Network, Engine, Torrent)
│   │   └── torrent_create/              # In-app .torrent creator
│   └── shared/
│       ├── design/                      # Reusable DMX component library
│       └── widgets/                     # Floating navigation, cards, sparklines
├── landing/                             # Modern floating-capsule landing website
├── xdm-firefox/                         # Companion Firefox Android extension
└── docs/                                # Technical design & protocol documentation
```

---

## 🛠️ Tech Stack

| Component | Library / Framework | Description |
| :--- | :--- | :--- |
| **Framework** | Flutter 3.x / Dart 3.0+ | Cross-platform native UI framework |
| **State Management** | Provider + `get_it` | Dependency injection & reactive state |
| **Storage & Database** | `drift` (SQLite) + Hive | High-speed relational database & key-value cache |
| **Networking** | `dio` + `cronet_http` | Multi-stream HTTP/2 & HTTP/3 QUIC client |
| **Download Engine** | Dart Isolates + ByteStreams | Multi-threaded file streaming & CRC32 journal |
| **BitTorrent** | `libtorrent_flutter` | P2P client with DHT, UPnP, and PEX |
| **Web Browser** | `flutter_inappwebview` | Chromium WebView with script & ad injection |
| **Media Processing** | `ffmpeg_kit_flutter` | Lossless video and audio stream muxing |
| **Security** | `flutter_secure_storage` + AES-256 | Encrypted credential and backup storage |

---

## 🚀 Getting Started

### Prerequisites
- [Flutter SDK](https://flutter.dev/docs/get-started/install) (Dart `>= 3.0.0`)
- Android SDK (min API 21+ / target API 34+)
- JDK 17+

### Clone & Run
```bash
# 1. Clone the repository
git clone https://github.com/DevEslam1/XDM.git
cd XDM

# 2. Install dependencies
flutter pub get

# 3. Run on connected Android device / emulator
flutter run
```

### Build Production APK
```bash
# Build optimized release APK
flutter build apk --release --split-per-abi
```
The compiled APK will be located at:
`build/app/outputs/flutter-apk/app-release.apk`

---

## 📖 Technical Documentation

Deep-dive into the internal architecture and protocols:

- 📘 [**Design System & Tokens**](design.md) — Comprehensive guide to typography, colors, animations, and components.
- 🚀 [**Download Engine Architecture**](docs/DOWNLOAD_ENGINE.md) — Chunk splitting, isolate pools, and CRC32 recovery.
- 🧲 [**Torrent & P2P Protocols**](docs/TORRENT_SUPPORT.md) — DHT bootstrapping, encryption, and tracker management.
- ♿ [**Accessibility Guide**](docs/ACCESSIBILITY.md) — Screen reader semantics, font scaling, and motion preferences.
- 🍏 [**iOS Implementation Spec**](docs/IOS_PLATFORM.md) — URLSession background downloads and WidgetKit integration.

---

## 🤝 Contributing

Contributions, issues, and feature requests are very welcome!

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📄 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

---

## 👨‍💻 Author

**Eslam Mahmoud** — *Mobile & Software Development Engineer*

- 🌐 **GitHub**: [@DevEslam1](https://github.com/DevEslam1)
- 💼 **LinkedIn**: [linkedin.com/in/deveslam-mahmoud](https://linkedin.com/in/deveslam-mahmoud)
- 📧 **Email**: xdev.eslam@gmail.com

<p align="center">
  <sub>Built with ❤️ using Flutter & Dart. If you like XDM, please give it a ⭐ on GitHub!</sub>
</p>