# ✅ XDM // Transmission Control Cockpit - Feature Checklist & Prompts

## 📋 Table of Contents
1. [UI/UX & Visual Identity](#1-uiux--visual-identity)
2. [Downloads Engine](#2-downloads-engine)
3. [Intelligent Categorization](#3-intelligent-categorization)
4. [Integrated Browser](#4-integrated-browser)
5. [Security & Background Services](#5-security--background-services)
6. [Settings & Configuration](#6-settings--configuration)
7. [Testing & Quality Assurance](#7-testing--quality-assurance)

---

## 1. UI/UX & Visual Identity

### 1.1 Glassmorphism Panels (GlassCard)
**Prompt:** 
> "Implement a reusable GlassCard widget with backdrop blur effect that adapts to light/dark themes. Must include a Visual Performance Mode toggle that disables blur effects for low-end devices."

- [ ] Backdrop blur effect working on Android/iOS/Windows
- [ ] Adaptive opacity based on theme (light/dark)
- [ ] Visual Performance Mode toggle in settings
- [ ] Fallback to solid color when Performance Mode is ON
- [ ] No jank or frame drops on low-end devices
- [ ] Border radius and padding consistent across all cards

### 1.2 Dynamic Neon Accents
**Prompt:**
> "Implement a cyberpunk neon color system (cyan, violet, green, red, amber) for status indicators and alerts. Colors must be theme-aware and accessible."

- [ ] Neon colors defined in theme palette
- [ ] Status colors: Cyan (active), Green (completed), Red (failed), Amber (paused), Violet (queued)
- [ ] Color contrast ratio >= 4.5:1 for accessibility
- [ ] Smooth color transitions between states
- [ ] No color bleeding on dark backgrounds

### 1.3 Geometric Mesh Backgrounds
**Prompt:**
> "Create programmatic grid mesh backgrounds with gradient blobs that reposition dynamically based on theme and scroll position."

- [ ] Grid lines render without performance issues
- [ ] Gradient blobs animate smoothly on theme change
- [ ] Background responds to scroll position (parallax effect)
- [ ] Fallback solid color for Performance Mode
- [ ] No memory leaks from animation controllers

### 1.4 Tactile Vibrations (HapticHelper)
**Prompt:**
> "Implement a HapticHelper utility that maps different vibration patterns to UI events: transitions, downloads, clicks, errors."

- [ ] Light impact on button clicks
- [ ] Medium impact on download start
- [ ] Heavy impact on download completion
- [ ] Error pattern on failures
- [ ] Respects system haptic settings
- [ ] Works on Android and iOS (Windows silent fallback)

### 1.5 3-Tab Navigation
**Prompt:**
> "Implement bottom navigation with 3 tabs: Downloads (main), Browser (web), Settings (config). Use persistent state with IndexedStack or equivalent."

- [ ] 3 tabs visible: Downloads, Browser, Settings
- [ ] Tab state persists on switch (no reload)
- [ ] Active tab indicator with neon accent
- [ ] Smooth transition animations
- [ ] Back button handling per tab
- [ ] Badge counts on Downloads tab (active count)

### 1.6 Segmented Dashboard (Active/Completed)
**Prompt:**
> "Implement sliding segmented control on Home screen to toggle between Active (downloading/paused/queued) and Completed (completed/failed) tasks."

- [ ] Segmented control at top of downloads list
- [ ] Active segment shows: downloading, paused, queued
- [ ] Completed segment shows: completed, failed
- [ ] Smooth slide animation between segments
- [ ] Pull-to-refresh on both segments
- [ ] Empty state illustrations for each segment

### 1.7 Collapsible Storage Analytics
**Prompt:**
> "Implement collapsible analytics panel at top of downloads with interactive Pie Chart (fl_chart) showing storage by category. Toggle via AppBar icon."

- [ ] Pie chart renders with 6 categories (Video, Audio, Document, Archive, APK, General)
- [ ] Interactive segments (tap to filter)
- [ ] Collapsible with smooth animation
- [ ] AppBar toggle icon changes state
- [ ] Real-time size calculations
- [ ] Empty state when no downloads

### 1.8 Add Download Screen
**Prompt:**
> "Create Quick Download screen with URL, filename, save path inputs. Include expandable Advanced Options drawer (Category, Connections, Schedule) hidden by default."

- [ ] URL input with validation and paste button
- [ ] Auto-extract filename from URL/headers
- [ ] Save path picker with default directory
- [ ] Advanced Options collapsible section
- [ ] Category dropdown (auto-detect + manual)
- [ ] Connections slider (1, 2, 4, 5, 8, 16)
- [ ] Schedule picker (date/time or immediate)
- [ ] Submit button with validation feedback

---

## 2. Downloads Engine

### 2.1 Multi-Threaded Range Pipeline
**Prompt:**
> "Implement parallel chunk download using HTTP Range headers. Split file into N threads, download to .part$index files, merge sequentially on completion."

- [ ] Dynamic chunk calculation based on file size and thread count
- [ ] Range header format: `bytes=start-end`
- [ ] Temporary files named: `.filename.part0`, `.filename.part1`, etc.
- [ ] Sequential merge after all chunks complete
- [ ] Progress tracking per chunk and total
- [ ] Cleanup of .part files after successful merge
- [ ] Resume support using existing .part files

### 2.2 Single-Thread Fallback
**Prompt:**
> "Implement graceful fallback to single-threaded download when server doesn't support Range headers or Content-Length is missing."

- [ ] HEAD request to check Accept-Ranges: bytes
- [ ] Fallback trigger on 416 Range Not Satisfiable
- [ ] Stream download without chunking when fallback
- [ ] Progress tracking via received bytes count
- [ ] No corruption on fallback transition
- [ ] Logging of fallback events

### 2.3 Rolling-Window Speed Estimation
**Prompt:**
> "Implement 3-second rolling window for download speed calculation to smooth out spikes and provide stable speed indicators."

- [ ] 3-second buffer of byte samples
- [ ] Average speed calculation every 500ms
- [ ] Smooth speed display (no erratic jumps)
- [ ] Time remaining calculation based on average speed
- [ ] Speed history graph in details screen
- [ ] Handles pause/resume without resetting window

### 2.4 Proxy Mode & SSL Bypass
**Prompt:**
> "Implement configurable proxy settings with SSL certificate bypass option for debugging. Show warning notice when SSL bypass is enabled."

- [ ] HTTP/HTTPS/SOCKS proxy configuration
- [ ] Host, port, username, password fields
- [ ] SSL bypass toggle with red warning banner
- [ ] Warning dialog on enabling SSL bypass
- [ ] Proxy applied to all download requests
- [ ] Test connection button for proxy

### 2.5 Monotonic Clocks
**Prompt:**
> "Use Stopwatch (monotonic clock) for all time measurements to prevent timezone change or system time adjustment errors."

- [ ] All duration calculations use Stopwatch
- [ ] No DateTime.difference for elapsed time
- [ ] Handles system time changes during download
- [ ] Handles timezone changes during download
- [ ] Accurate time remaining predictions

### 2.6 Collision-Safe Task IDs
**Prompt:**
> "Generate unique task IDs using microsecond timestamp + random offset to prevent collisions even with rapid successive downloads."

- [ ] Format: `{microsecondTimestamp}_{randomOffset}`
- [ ] Cryptographically secure random component
- [ ] No collisions in stress test (1000 rapid downloads)
- [ ] Used as primary key in Hive database
- [ ] Consistent ID across app restarts

### 2.7 Flexible Connection Channel Controls
**Prompt:**
> "Allow configurable thread counts per task (1, 2, 4, 5, 8, 16) with safety guards to prevent changing threads during active download."

- [ ] Preset values: 1, 2, 4, 5, 8, 16
- [ ] Default setting in global config
- [ ] Per-task override in Add Download screen
- [ ] Thread count locked during active download
- [ ] Warning if server doesn't support requested threads
- [ ] Auto-adjust if file size is too small for N threads

---

## 3. Intelligent Categorization

### 3.1 Automatic Category Indexing
**Prompt:**
> "Auto-classify downloads into Video, Audio, Document, Archive, APK, General based on MIME type and file extension."

- [ ] Video: .mp4, .mkv, .avi, .mov, .webm, .flv, .wmv
- [ ] Audio: .mp3, .wav, .flac, .aac, .ogg, .m4a, .wma
- [ ] Document: .pdf, .doc, .docx, .xls, .xlsx, .ppt, .pptx, .txt
- [ ] Archive: .zip, .rar, .7z, .tar, .gz, .bz2
- [ ] APK: .apk, .xapk
- [ ] General: everything else
- [ ] MIME type detection from Content-Type header
- [ ] Override capability in Add Download screen

### 3.2 Interactive Dashboard Filters
**Prompt:**
> "Allow tapping category badges in analytics panel to filter downloads list. Show clearable filter chips."

- [ ] Tap pie chart segment filters list
- [ ] Filter chip appears below AppBar
- [ ] Chip shows category name + count + clear button
- [ ] Multiple category selection allowed
- [ ] Filter persists during tab switch
- [ ] Empty state when filter returns no results

### 3.3 Categorized Folder Docks
**Prompt:**
> "Automatically save files into subdirectories matching their category: /Downloads/Video/, /Downloads/Audio/, etc."

- [ ] Default save path includes category subfolder
- [ ] Folder created automatically if not exists
- [ ] Category folder names localized
- [ ] Override in Add Download screen
- [ ] Handles permission errors gracefully
- [ ] No duplicate folder creation

---

## 4. Integrated Browser

### 4.1 Direct Web Sniffer
**Prompt:**
> "Implement inline WebView browser that detects downloadable resources and intercepts navigation to capture download URLs."

- [ ] WebView renders pages correctly
- [ ] Detects `<a>` tags with download attributes
- [ ] Intercepts file MIME types automatically
- [ ] Shows download prompt on detection
- [ ] Handles redirects (301/302)
- [ ] Custom user agent support

### 4.2 Broad Download Interception
**Prompt:**
> "Capture redirects, data URIs, base64 streams, blob URLs, and custom requests with complex query matching."

- [ ] Redirect chain following (up to 10 hops)
- [ ] Data URI parsing (`data:application/...`)
- [ ] Base64 decoding and saving
- [ ] Blob URL interception
- [ ] Custom user-agent per request
- [ ] Regex pattern matching for URLs
- [ ] m3u8/HLS stream detection

### 4.3 Multi-Tab Support
**Prompt:**
> "Support multiple concurrent tabs using IndexedStack with separate WebView instances. Include tab grid switcher and incognito mode."

- [ ] Maximum 10 tabs (configurable)
- [ ] IndexedStack for state preservation
- [ ] Tab grid switcher UI (visual thumbnails)
- [ ] Incognito tabs (no history, no cache)
- [ ] Tab close button with confirmation
- [ ] Tab title and favicon display
- [ ] Memory cleanup on tab close

### 4.4 Edge Swipe Navigation
**Prompt:**
> "Implement edge swipe gestures: left edge drag = go back, right edge drag = go forward."

- [ ] Left edge swipe triggers back navigation
- [ ] Right edge swipe triggers forward navigation
- [ ] Visual feedback during swipe
- [ ] Respects WebView history stack
- [ ] No conflict with horizontal scrolling
- [ ] Configurable sensitivity

### 4.5 Offline Page Cache
**Prompt:**
> "Save current page DOM as offline .html file in downloads folder with local file access."

- [ ] Save button in browser menu
- [ ] Captures full DOM structure
- [ ] Saves to /Downloads/Web/ or category folder
- [ ] Filename: `{page_title}_{timestamp}.html`
- [ ] Images saved as base64 inline or separate folder
- [ ] Open saved file in browser confirmation

### 4.6 JS Injection / Custom CSS Editor
**Prompt:**
> "Implement persistent tabbed script editor for custom CSS and JavaScript that auto-injects on page load."

- [ ] Tabbed editor: CSS tab + JS tab
- [ ] Code syntax highlighting
- [ ] Auto-inject on every page load
- [ ] Per-site or global scope toggle
- [ ] Enable/disable toggle per script
- [ ] Scripts saved to Hive database
- [ ] Preview changes in real-time

### 4.7 Video Quality Selector
**Prompt:**
> "Show bottom sheet with detected video stream qualities/resolutions for selection before download."

- [ ] Detects `<video>` tags and HLS streams
- [ ] Parses m3u8 manifest for quality variants
- [ ] Bottom sheet with quality list (1080p, 720p, etc.)
- [ ] Shows file size estimate per quality
- [ ] Download selected quality directly
- [ ] Fallback to best quality if no selection
- [ ] Works with DASH streams too

### 4.8 Smart Surf & Download History
**Prompt:**
> "Unified searchable history page with segmented view: Surfing History (visited pages) and Download History (completed tasks)."

- [ ] Segmented control: Surfing | Downloads
- [ ] Search bar with real-time filtering
- [ ] Surfing: URL, title, timestamp, favicon
- [ ] Downloads: filename, size, status, timestamp
- [ ] Clear history button with confirmation
- [ ] Export history to JSON
- [ ] Infinite scroll or pagination

---

## 5. Security & Background Services

### 5.1 Biometric Gate Lock
**Prompt:**
> "Implement local_auth biometric lock on app launch and when returning from background. Show lock screen overlay."

- [ ] Fingerprint/FaceID prompt on cold start
- [ ] Re-prompt when app resumes from background
- [ ] Lock screen overlay (blur + icon)
- [ ] Fallback to PIN/Password if biometric fails
- [ ] Toggle in Settings (enable/disable)
- [ ] No sensitive data visible behind lock
- [ ] Android and iOS compatibility

### 5.2 Heartbeat Background Service
**Prompt:**
> "Run 15-second heartbeat background service that monitors download progress when app is minimized."

- [ ] Service starts on first download
- [ ] 15-second interval check
- [ ] Updates notification progress
- [ ] Handles app kill gracefully (resume on restart)
- [ ] Battery optimization aware
- [ ] Android foreground service notification
- [ ] iOS background fetch implementation

### 5.3 System Notification Quick Actions
**Prompt:**
> "Android notifications with Pause and Cancel buttons that communicate with main isolate via named ReceivePorts."

- [ ] Progress notification with percentage
- [ ] Pause button in notification
- [ ] Cancel button in notification
- [ ] Actions map to ReceivePorts
- [ ] Pause resumes correctly
- [ ] Cancel cleans up .part files
- [ ] Notification dismissed on completion

### 5.4 System Backups
**Prompt:**
> "Export all downloads metadata to JSON file and import from JSON to restore state."

- [ ] Export button in Settings
- [ ] JSON format with all task metadata
- [ ] Include: URLs, paths, progress, categories, settings
- [ ] Import validates JSON schema
- [ ] Merge or replace option on import
- [ ] Share exported file via system dialog
- [ ] Backup encryption option (password)

---

## 6. Settings & Configuration

### 6.1 Global Configuration
**Prompt:**
> "Settings screen with all global configs: default threads, default path, theme, language, notifications, proxy, biometric, performance mode."

- [ ] Default connection threads (1, 2, 4, 5, 8, 16)
- [ ] Default save directory picker
- [ ] Theme mode (Light/Dark/System)
- [ ] Language selection (Arabic/English/...)
- [ ] Notification toggle
- [ ] Proxy configuration screen
- [ ] Biometric lock toggle
- [ ] Performance mode toggle
- [ ] Reset to defaults button

### 6.2 Theme Management
**Prompt:**
> "Implement full theme system with light/dark modes, neon accent colors, and system theme following."

- [ ] Light theme with glassmorphism
- [ ] Dark theme with neon accents
- [ ] System theme following
- [ ] Custom accent color picker (optional)
- [ ] Theme change without restart
- [ ] Persist theme choice in Hive

---

## 7. Testing & Quality Assurance

### 7.1 Unit Tests
**Prompt:**
> "Write comprehensive unit tests for download provider, task models, and URL utilities."

- [ ] `test/download_provider_test.dart` passes
- [ ] `test/download_task_test.dart` passes
- [ ] `test/url_file_utils_test.dart` passes
- [ ] Mock Dio for network testing
- [ ] Mock Hive for database testing
- [ ] 80%+ code coverage on core logic

### 7.2 Integration Tests
**Prompt:**
> "Write integration tests for full download flow: add task -> download -> complete -> verify file."

- [ ] Full download flow test
- [ ] Pause/resume flow test
- [ ] Multi-thread vs single-thread test
- [ ] Error handling test (404, no network)
- [ ] Browser download interception test
- [ ] Biometric lock flow test

### 7.3 Platform-Specific Tests
**Prompt:**
> "Verify functionality on Android, iOS, and Windows platforms."

- [ ] Android: Permissions, notifications, background service
- [ ] iOS: Background fetch, local auth, WebView
- [ ] Windows: File paths, notifications, UI scaling
- [ ] Responsive layout on different screen sizes
- [ ] Performance on low-end devices
- [ ] Memory leak testing (long-running downloads)

---

## 🔍 Quick Verification Commands

```bash
# Run all unit tests
flutter test test/download_provider_test.dart test/download_task_test.dart test/url_file_utils_test.dart

# Build for platforms
flutter build apk --release
flutter build ios --release
flutter build windows --release

# Check for analysis issues
flutter analyze

# Format code
flutter format lib/
```

---

## 📊 Success Criteria

| Feature Area | Critical Items | Must Pass Tests |
|-------------|---------------|----------------|
| UI/UX | 8 | All visual elements render correctly |
| Downloads Engine | 7 | No corruption, accurate progress, resume works |
| Categorization | 3 | Correct auto-detection, proper folder structure |
| Browser | 8 | Interception works, tabs stable, history accurate |
| Security | 4 | Biometric prompt, background service stable |
| Settings | 2 | All toggles persist and apply immediately |
| Testing | 3 | 80%+ coverage, all integration tests pass |

**Total Checklist Items: 35**
**Minimum Required: 35/35 for production release**
