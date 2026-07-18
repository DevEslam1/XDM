# ⚡ XDM // XTREME DOWNLOAD MANAGER

<p align="center">
  <img src="assets/app_icon/icon.png" width="128" height="128" alt="XDM Icon" style="border-radius: 28%;" />
</p>

<p align="center">
  <strong>A premium Flutter download manager — multi-threaded, YouTube-ready, torrent-capable.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.12+-02569B?logo=flutter&logoColor=white&style=for-the-badge" alt="Flutter" />
  <img src="https://img.shields.io/badge/Dart-3.0+-0175C2?logo=dart&logoColor=white&style=for-the-badge" alt="Dart" />
  <img src="https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Windows-000000?style=for-the-badge" alt="Platforms" />
  <img src="https://img.shields.io/badge/Version-3.0.0-blue?style=for-the-badge" alt="Version" />
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License" />
</p>

---

## ✨ Features

### Download Engine
- **Multi-threaded parallel downloads** — dynamic file segmentation with configurable threads (1–16)
- **Single-thread fallback** — auto-switches when servers don't support range headers
- **Resume broken downloads** — continue from where they left off after interruptions
- **Download scheduling** — queue tasks by time, battery-aware, speed limiter
- **Rolling-window speed estimation** — smooth 3-second interval for accurate speed display

### YouTube Integration
- **Video & audio stream fetching** — powered by `youtube_explode_dart`
- **Playlist support** — batch download entire playlists
- **Auto URL detection** — recognizes all YouTube formats (watch, embed, live, music, shorts)
- **Quality selector** — choose resolution / format before downloading

### Built-in Browser
- **WebView tab manager** — multiple tabs with swipe navigation
- **Download interception** — auto-detects files, videos, and assets on any page
- **Bookmarks & history** — persistent with search and filtering
- **Incognito mode** — private tabs with no history tracking
- **Offline page cache** — save pages as HTML for offline access

### BitTorrent
- **Magnet / torrent file support** — via libtorrent FFI binding
- **File selection** — view and choose individual files within torrents
- **Sequential download** — stream media while downloading

### UI / UX
- **Cyberpunk neon cockpit** — glassmorphism, dynamic mesh backgrounds, haptic feedback
- **Dark / Light / System themes** — theme-aware with accent colors
- **Analytics dashboard** — interactive donut chart with category breakdown
- **Category filters** — tap badges to filter the active downloads list
- **RTL support** — full Arabic localization
- **Biometric lock** — fingerprint / face unlock on launch and resume
- **Adaptive layouts** — responsive design for phones, tablets, and desktop

### Notifications & Background
- **Foreground service** — heartbeat monitor for active downloads
- **Quick actions** — pause / cancel from Android notification drawer
- **System notifications** — download complete, error, and progress updates

---

## 🛠️ Tech Stack

| Layer | Technology |
|-------|-----------|
| **Framework** | Flutter (Dart SDK ^3.12.0) |
| **State Management** | Provider |
| **Local Storage** | Hive + SharedPreferences |
| **Networking** | Dio ^5.9.2 |
| **YouTube** | youtube_explode_dart ^3.1.0 |
| **Torrent** | libtorrent FFI |
| **Auth** | local_auth |
| **Charts** | fl_chart |
| **Notifications** | flutter_local_notifications |
| **Background Service** | flutter_background_service |

---

## 📁 Project Structure

```
lib/
├── core/
│   ├── services/       # Database, Download Engine, Permissions, Notifications, YouTube, Torrent
│   └── utils/          # Haptics, Localization, Constants, File Utils, URL Utils
├── features/
│   ├── add_download/   # New download screen (URL, filename, category, threads, schedule)
│   ├── browser/        # WebView browser with download sniffing, bookmarks, history
│   ├── categories/     # Legacy — integrated into home dashboard
│   ├── details/        # Task detail screen (speed graph, thread control, logs)
│   ├── downloads/      # Download provider & state management
│   ├── history/        # Legacy — integrated into home dashboard
│   ├── home/           # Dashboard (analytics, active/completed tabs, filters)
│   ├── onboarding/     # Splash screen + biometric lock
│   └── settings/       # App configuration (themes, network, notifications, about)
└── shared/
    └── widgets/        # Reusable components (GlassCard, NeonButton, GridMesh, etc.)
```

---

## 🚀 Getting Started

### Prerequisites
- Flutter SDK `>= 3.12.0`
- Android SDK (min API 24), iOS 12.0+, or Windows 10+

### Installation
```bash
git clone https://github.com/DevEslam1/XDM.git
cd XDM
flutter pub get
flutter run
```

### Run Tests
```bash
flutter test
```

---

## ⚙️ Platform Configuration

### Android Permissions (`AndroidManifest.xml`)
- `INTERNET`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`
- `ACCESS_NETWORK_STATE`, `RECEIVE_BOOT_COMPLETED`, `POST_NOTIFICATIONS`

### iOS
- Background processing registered in `Info.plist`

---

## 📄 License

MIT License — see [LICENSE](LICENSE).

---

## 👨‍💻 Developer

**Eslam Mahmoud** — Mobile Development Engineer

- Email: xdev.eslam@gmail.com
- GitHub: [github.com/DevEslam1](https://github.com/DevEslam1)
- LinkedIn: [linkedin.com/in/deveslam-mahmoud](https://linkedin.com/in/deveslam-mahmoud)
