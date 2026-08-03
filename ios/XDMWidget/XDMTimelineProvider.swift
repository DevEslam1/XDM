import WidgetKit
import Foundation

struct XDMTimelineProvider: TimelineProvider {

    func placeholder(in context: Context) -> XDMWidgetEntry {
        XDMWidgetEntry(
            date: Date(),
            tasks: [
                WidgetTaskSummaryItem(
                    id: "sample_1",
                    fileName: "ubuntu-24.04-desktop-amd64.iso",
                    status: "downloading",
                    progress: 0.65,
                    speedBytesPerSec: 5_242_880,
                    etaSeconds: 180,
                    fileSizeBytes: 2_500_000_000,
                    downloadedBytes: 1_625_000_000,
                    category: "Video",
                    isTorrent: false,
                    isAppUpdate: false
                ),
                WidgetTaskSummaryItem(
                    id: "sample_2",
                    fileName: "album_master_2026.zip",
                    status: "downloading",
                    progress: 0.30,
                    speedBytesPerSec: 2_097_152,
                    etaSeconds: 420,
                    fileSizeBytes: 800_000_000,
                    downloadedBytes: 240_000_000,
                    category: "Archive",
                    isTorrent: true,
                    isAppUpdate: false
                )
            ],
            totalActiveCount: 2,
            totalSpeedBytesPerSec: 7_340_032,
            completedTodayCount: 8,
            failedCount: 0,
            availableStorageBytes: 12_800_000_000,
            isOnWifi: true,
            selectedTab: "downloading"
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (XDMWidgetEntry) -> Void
    ) {
        let entry = XDMWidgetDataLoader.loadStats() ?? placeholder(in: context)
        completion(entry)
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<XDMWidgetEntry>) -> Void
    ) {
        let entry = XDMWidgetDataLoader.loadStats() ?? placeholder(in: context)

        // Adaptive refresh policy:
        // - Active downloads: every 30 seconds for smooth progress updates
        // - Paused/queued only: every 2 minutes
        // - All idle/completed: every 15 minutes
        let hasActiveDownloads = entry.tasks.contains { $0.status == "downloading" }
        let hasQueuedOrPaused = entry.tasks.contains { $0.status == "queued" || $0.status == "paused" }

        let refreshInterval: TimeInterval
        if hasActiveDownloads {
            refreshInterval = 30 // Fast updates while downloading
        } else if hasQueuedOrPaused {
            refreshInterval = 120 // Medium updates for queued tasks
        } else {
            refreshInterval = 900 // Slow updates when idle
        }

        // Generate multiple entries for smooth progress animation
        // (iOS will interpolate between entries)
        var entries: [XDMWidgetEntry] = [entry]

        if hasActiveDownloads {
            // Add 2 more entries with estimated progress for smooth animation
            let nextDate = Date().addingTimeInterval(refreshInterval / 2)
            let estimatedEntry = XDMWidgetEntry(
                date: nextDate,
                tasks: entry.tasks.map { task in
                    if task.status == "downloading" && task.etaSeconds != nil && task.etaSeconds! > 0 {
                        let progressDelta = 1.0 / Double(task.etaSeconds!) * (refreshInterval / 2)
                        let newProgress = min(1.0, task.progress + progressDelta)
                        var updated = task
                        updated.progress = newProgress
                        updated.downloadedBytes = Int64(Double(task.fileSizeBytes) * newProgress)
                        if let eta = task.etaSeconds {
                            updated.etaSeconds = max(0, eta - Int(refreshInterval / 2))
                        }
                        return updated
                    }
                    return task
                },
                totalActiveCount: entry.totalActiveCount,
                totalSpeedBytesPerSec: entry.totalSpeedBytesPerSec,
                completedTodayCount: entry.completedTodayCount,
                failedCount: entry.failedCount,
                availableStorageBytes: entry.availableStorageBytes,
                isOnWifi: entry.isOnWifi,
                selectedTab: entry.selectedTab
            )
            entries.append(estimatedEntry)
        }

        let timeline = Timeline(
            entries: entries,
            policy: .after(Date().addingTimeInterval(refreshInterval))
        )
        completion(timeline)
    }
}
