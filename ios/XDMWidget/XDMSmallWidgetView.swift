import SwiftUI
import WidgetKit

struct XDMSmallWidgetView: View {
    var entry: XDMWidgetEntry

    private var topTask: WidgetTaskSummaryItem? {
        entry.tasks.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Text("XDM")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 59/255, green: 130/255, blue: 246/255)) // #3B82F6

                Spacer()

                if entry.totalSpeedBytesPerSec > 0 {
                    Text(XDMWidgetDataLoader.formatSpeed(entry.totalSpeedBytesPerSec))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 16/255, green: 185/255, blue: 129/255)) // #10B981
                }
            }

            Spacer()

            if let task = topTask {
                // Category pill
                Text(formatCategory(task))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Color(red: 139/255, green: 92/255, blue: 246/255))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(red: 139/255, green: 92/255, blue: 246/255).opacity(0.18))
                    .cornerRadius(4)

                // Title
                Text(task.fileName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                    .foregroundColor(Color(red: 242/255, green: 244/255, blue: 248/255))

                // Progress bar
                ProgressView(value: task.status == "completed" ? 1.0 : task.progress)
                    .tint(task.status == "completed" ? Color(red: 16/255, green: 185/255, blue: 129/255) : Color(red: 59/255, green: 130/255, blue: 246/255))

                // Action / Stats row
                HStack {
                    if task.status == "completed" {
                        Text("Completed · \(XDMWidgetDataLoader.formatBytes(task.fileSizeBytes))")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Spacer()
                        Link(destination: URL(string: "dmx://open/\(task.id)")!) {
                            Text("OPEN")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Color(red: 16/255, green: 185/255, blue: 129/255))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(red: 16/255, green: 185/255, blue: 129/255).opacity(0.2))
                                .cornerRadius(4)
                        }
                    } else {
                        Text("\(Int(task.progress * 100))%")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 16/255, green: 185/255, blue: 129/255))
                        Spacer()
                        let isPaused = task.status == "paused" || task.status == "failed"
                        Link(destination: URL(string: "dmx://toggle/\(task.id)")!) {
                            Text(isPaused ? "▶" : "❚❚")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(isPaused ? Color(red: 16/255, green: 185/255, blue: 129/255) : Color(red: 59/255, green: 130/255, blue: 246/255))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((isPaused ? Color(red: 16/255, green: 185/255, blue: 129/255) : Color(red: 59/255, green: 130/255, blue: 246/255)).opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                }
            } else {
                Text("ALL CLEAR")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(red: 16/255, green: 185/255, blue: 129/255))
                Text("No active downloads")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Footer
            HStack {
                Text("\(entry.totalActiveCount) active · \(entry.completedTodayCount) done")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
        }
        .padding(11)
        .background(Color(red: 15/255, green: 17/255, blue: 23/255))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(red: 59/255, green: 130/255, blue: 246/255).opacity(0.24), lineWidth: 1.2)
        )
    }

    private func formatCategory(_ task: WidgetTaskSummaryItem) -> String {
        if task.isTorrent { return "TORRENT" }
        if task.isAppUpdate { return "UPDATE" }
        let cat = task.category.uppercased()
        return cat.isEmpty || cat == "OTHER" ? "FILE" : cat
    }
}
