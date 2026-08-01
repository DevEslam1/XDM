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
        .description("Monitor your active downloads and speed.")
        .supportedFamilies([.systemSmall, .systemMedium])
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
            activeCount: 3,
            speedBytesPerSec: 10_485_760,
            completedCount: 25,
            progress: 0.72,
            topFileName: "ubuntu-24.04-desktop-amd64.iso"
        )

        XDMSmallWidgetView(entry: entry)
            .previewContext(WidgetPreviewContext(family: .systemSmall))

        XDMMediumWidgetView(entry: entry)
            .previewContext(WidgetPreviewContext(family: .systemMedium))
    }
}
