import WidgetKit
import SwiftUI

@main
struct XDMWidgetBundle: WidgetBundle {
    var body: some Widget {
        XDMDownloadWidget()
        if #available(iOS 16.1, *) {
            XDMLiveActivityWidget()
        }
    }
}

struct XDMDownloadWidget: Widget {
    let kind: String = "XDMDownloadWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: XDMTimelineProvider()) { entry in
            XDMWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("XDM Downloads")
        .description("Monitor your active/completed downloads, speed, and status.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled() // We handle our own padding
    }
}

struct XDMWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: XDMWidgetEntry

    var body: some View {
        switch family {
        case .systemSmall:
            XDMSmallWidgetView(entry: entry)
        case .systemMedium:
            XDMMediumWidgetView(entry: entry)
        case .systemLarge:
            XDMWidgetLargeView(entry: entry)
        default:
            XDMSmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Previews

struct XDMWidget_Previews: PreviewProvider {
    static var previews: some View {
        let entry = XDMWidgetEntry(
            date: Date(),
            tasks: [
                WidgetTaskSummaryItem(
                    id: "preview_1",
                    fileName: "ubuntu-24.04-desktop-amd64.iso",
                    status: "downloading",
                    progress: 0.72,
                    speedBytesPerSec: 10_485_760,
                    etaSeconds: 120,
                    fileSizeBytes: 2_500_000_000,
                    downloadedBytes: 1_800_000_000,
                    category: "Video",
                    isTorrent: false,
                    isAppUpdate: false
                ),
                WidgetTaskSummaryItem(
                    id: "preview_2",
                    fileName: "album_master_2026.zip",
                    status: "downloading",
                    progress: 0.35,
                    speedBytesPerSec: 3_145_728,
                    etaSeconds: 340,
                    fileSizeBytes: 800_000_000,
                    downloadedBytes: 280_000_000,
                    category: "Archive",
                    isTorrent: true,
                    isAppUpdate: false
                ),
                WidgetTaskSummaryItem(
                    id: "preview_3",
                    fileName: "presentation_final.pdf",
                    status: "completed",
                    progress: 1.0,
                    speedBytesPerSec: 0,
                    etaSeconds: nil,
                    fileSizeBytes: 45_000_000,
                    downloadedBytes: 45_000_000,
                    category: "Document",
                    isTorrent: false,
                    isAppUpdate: false
                )
            ],
            totalActiveCount: 2,
            totalSpeedBytesPerSec: 13_631_488,
            completedTodayCount: 25,
            failedCount: 1,
            availableStorageBytes: 64_000_000_000,
            isOnWifi: true,
            selectedTab: "downloading"
        )

        XDMSmallWidgetView(entry: entry)
            .previewContext(WidgetPreviewContext(family: .systemSmall))

        XDMMediumWidgetView(entry: entry)
            .previewContext(WidgetPreviewContext(family: .systemMedium))

        XDMWidgetLargeView(entry: entry)
            .previewContext(WidgetPreviewContext(family: .systemLarge))
    }
}
