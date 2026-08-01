import SwiftUI
import WidgetKit

// MARK: - Small Widget View
struct XDMSmallWidgetView: View {
    var entry: XDMWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)
                    .font(.title2)
                Spacer()
                Text("\(entry.activeCount)")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
            }

            Spacer()

            // Speed
            Text(formatSpeed(entry.speedBytesPerSec))
                .font(.caption)
                .foregroundColor(.secondary)

            // Progress bar
            ProgressView(value: entry.progress)
                .tint(.blue)
        }
        .padding()
    }

    private func formatSpeed(_ bytesPerSec: Int64) -> String {
        let mbPerSec = Double(bytesPerSec) / (1024 * 1024)
        if mbPerSec >= 1.0 {
            return String(format: "%.1f MB/s", mbPerSec)
        }
        let kbPerSec = Double(bytesPerSec) / 1024
        return String(format: "%.0f KB/s", kbPerSec)
    }
}

// MARK: - Medium Widget View
struct XDMMediumWidgetView: View {
    var entry: XDMWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)
                    .font(.title3)
                Text("XDM Downloads")
                    .font(.headline)
                Spacer()
            }

            // Stats row
            HStack(spacing: 20) {
                StatView(
                    label: "Active",
                    value: "\(entry.activeCount)",
                    icon: "bolt.fill",
                    color: .blue
                )
                StatView(
                    label: "Speed",
                    value: formatSpeed(entry.speedBytesPerSec),
                    icon: "speedometer",
                    color: .green
                )
                StatView(
                    label: "Done",
                    value: "\(entry.completedCount)",
                    icon: "checkmark.circle.fill",
                    color: .green
                )
            }

            Spacer()

            // Current download
            if !entry.topFileName.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.topFileName)
                        .font(.caption)
                        .lineLimit(1)
                    ProgressView(value: entry.progress)
                        .tint(.blue)
                    Text("\(Int(entry.progress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }

    private func formatSpeed(_ bytesPerSec: Int64) -> String {
        let mbPerSec = Double(bytesPerSec) / (1024 * 1024)
        if mbPerSec >= 1.0 {
            return String(format: "%.1f MB/s", mbPerSec)
        }
        return String(format: "%.0f KB/s", Double(bytesPerSec) / 1024)
    }
}

struct StatView: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.caption)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
