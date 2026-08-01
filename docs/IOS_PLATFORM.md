# iOS Platform Ecosystem Architecture

## Overview
XDM provides a deep native iOS integration supporting background out-of-process downloads (`URLSession`), WidgetKit home screen widgets, Share Extension, Live Activities, and App Intents.

## Native Subsystems
1. **Background Downloads & ATS**:
   - `XDMBackgroundDownloadManager` uses native `URLSessionConfiguration.background`.
   - `Info.plist` configures `NSAllowsArbitraryLoads = true` for arbitrary user file URLs while enforcing TLS 1.2+ minimum security for backend endpoints.

2. **WidgetKit & Shared Storage**:
   - Shared container (`group.com.dmx.app`) stores active download metrics in `xdm_widget_stats.json`.
   - `XDMWidget` renders Small and Medium SwiftUI widgets updating every 5 minutes.

3. **Share Extension**:
   - `ShareViewController` accepts URLs or plain text from Safari or other iOS apps and forwards them via `dmx://share?url=` scheme.

4. **Live Activities (Dynamic Island & Lock Screen)**:
   - `XDMLiveActivityWidget` exposes ActivityKit dynamic island and lock screen download progress views on iOS 16.1+.

5. **App Intents & Siri Shortcuts**:
   - `StartDownloadIntent` and `PauseAllDownloadsIntent` integrate directly with Siri and the iOS Shortcuts app.
