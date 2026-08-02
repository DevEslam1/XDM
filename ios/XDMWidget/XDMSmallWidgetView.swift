import SwiftUI
import WidgetKit

struct XDMSmallWidgetView: View {
    var entry: XDMWidgetEntry
    @Environment(\.colorScheme) var colorScheme

    private var accentColor: Color {
        entry.isDownloading ? .blue : .gray
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: entry.isDownloading
                      ? "arrow.down.circle.fill"
                      : "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(accentColor)

                Spacer()

                if entry.isDownloading {
                    Text(XDMWidgetDataLoader.formatSpeed(entry.speedBytesPerSec))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 6)

            Spacer()

            // Active count
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(entry.activeCount)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(accentColor)
                Text("active")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            // Progress bar (if downloading)
            if entry.isDownloading && entry.topFileProgress > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: entry.topFileProgress)
                        .tint(accentColor)
                    Text("\(Int(entry.topFileProgress * 100))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }

            Spacer()

            // Footer: completed count
            HStack {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 9))
                    .foregroundColor(.green)
                Text("\(entry.completedCount) done")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(14)
    }
}
