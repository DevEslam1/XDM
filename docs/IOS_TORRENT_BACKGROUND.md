# iOS Torrent Background Behavior

## iOS Limitation
iOS does NOT allow arbitrary background code execution for P2P protocols. `libtorrent` runs in-process and CANNOT continue downloading when the app is suspended.

## Our Strategy: Graceful Fast-Resume

1. **App enters background:**
   - Save fast-resume data for all active torrents to `UserDefaults`
   - Schedule a `BGProcessingTask` (15-min interval: `com.dmx.app.torrent.refresh`)
   - Notify Flutter layer to persist torrent state to DB

2. **App returns to foreground:**
   - Cancel pending `BGProcessingTask`
   - Load fast-resume data from `UserDefaults`
   - Resume torrents from saved state (near-instant, skipping full re-check)

3. **BGProcessingTask fires (every 15 min):**
   - Reschedule next background task execution
   - Mark task completed cleanly

## User Experience
- Torrent downloads pause when app is backgrounded (iOS system rule)
- Torrent downloads resume automatically when app returns to foreground
- Fast-resume data prevents full piece re-checking (saves minutes of hashing)
- UI displays `"Pauses in background"` indicator on active torrent download cards
