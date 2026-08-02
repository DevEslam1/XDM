import WidgetKit

struct XDMTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> XDMWidgetEntry {
        XDMWidgetEntry(
            date: Date(),
            activeCount: 2,
            speedBytesPerSec: 5_242_880,
            completedCount: 15,
            totalDownloads: 42,
            topFileName: "ubuntu-24.04-desktop-amd64.iso",
            topFileProgress: 0.65,
            isDownloading: true
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
        // - If downloading: every 1 minute (active progress)
        // - If idle: every 15 minutes (just stats)
        let refreshInterval: TimeInterval = entry.isDownloading ? 60 : 900
        let nextUpdate = Date().addingTimeInterval(refreshInterval)

        let timeline = Timeline(
            entries: [entry],
            policy: .after(nextUpdate)
        )
        completion(timeline)
    }
}
