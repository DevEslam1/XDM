import WidgetKit

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
                    category: "ISO",
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
                    category: "ZIP",
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

        // Refresh policy:
        // - If active downloads: every 1 minute
        // - If idle: every 15 minutes
        let refreshInterval: TimeInterval = entry.totalActiveCount > 0 ? 60 : 900
        let nextUpdate = Date().addingTimeInterval(refreshInterval)

        let timeline = Timeline(
            entries: [entry],
            policy: .after(nextUpdate)
        )
        completion(timeline)
    }
}
