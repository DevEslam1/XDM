import SwiftUI
import WidgetKit

struct XDMMediumWidgetView: View {
    var entry: XDMWidgetEntry
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 16) {
            // Left column: Stats
            VStack(alignment: .leading, spacing: 10) {
                // App identity
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.blue)
                    Text("XDM")
                        .font(.system(size: 14, weight: .bold))
                }

                // Stats grid
                HStack(spacing: 14) {
                    StatColumn(
                        value: "\(entry.activeCount)",
                        label: "Active",
                        color: entry.activeCount > 0 ? .blue : .gray
                    )
                    StatColumn(
                        value: XDMWidgetDataLoader.formatSpeed(entry.speedBytesPerSec),
                        label: "Speed",
                        color: .green
                    )
                    StatColumn(
                        value: "\(entry.completedCount)",
                        label: "Done",
                        color: .green
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Divider
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 1)

            // Right column: Current download
            VStack(alignment: .leading, spacing: 8) {
                if entry.isDownloading && !entry.topFileName.isEmpty {
                    // Current file
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.topFileName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(2)
                            .foregroundColor(.primary)

                        ProgressView(value: entry.topFileProgress)
                            .tint(.blue)

                        HStack {
                            Text("\(Int(entry.topFileProgress * 100))%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(XDMWidgetDataLoader.formatSpeed(entry.speedBytesPerSec))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.blue)
                        }
                    }
                } else {
                    // Idle state
                    VStack(spacing: 6) {
                        Image(systemName: "tray.full")
                            .font(.system(size: 24))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("No active downloads")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }
}

struct StatColumn: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }
}
