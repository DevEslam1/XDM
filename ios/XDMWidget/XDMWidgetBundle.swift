import WidgetKit
import SwiftUI

@main
struct XDMWidgetBundle: WidgetBundle {
    var body: some Widget {
        XDMDownloadWidget()
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
                    category: "ISO",
                    isTorrent: false,
                    isAppUpdate: false
                )
            ],
            totalActiveCount: 3,
            totalSpeedBytesPerSec: 10_485_760,
            completedTodayCount: 25,
            failedCount: 0,
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
