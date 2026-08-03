import SwiftUI
import WidgetKit

struct XDMMediumWidgetView: View {
    var entry: XDMWidgetEntry

    @State private var activeTab: String = "downloading"

    private var currentTabTasks: [WidgetTaskSummaryItem] {
        let selected = entry.selectedTab
        if selected == "completed" {
            return entry.tasks.filter { $0.status == "completed" }
        } else {
            return entry.tasks.filter { $0.status != "completed" }
        }
    }

    private var activeCount: Int {
        entry.tasks.filter { $0.status != "completed" }.count
    }

    private var completedCount: Int {
        entry.tasks.filter { $0.status == "completed" }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 2-Tab Header Bar
            HStack(spacing: 8) {
                // Downloading Tab button
                Link(destination: URL(string: "dmx://downloads")!) {
                    HStack(spacing: 4) {
                        Text("DOWNLOADING (\(activeCount))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(entry.selectedTab != "completed" ? Color(red: 59/255, green: 130/255, blue: 246/255) : Color(red: 154/255, green: 163/255, blue: 181/255))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(entry.selectedTab != "completed" ? Color(red: 59/255, green: 130/255, blue: 246/255).opacity(0.18) : Color.clear)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(entry.selectedTab != "completed" ? Color(red: 59/255, green: 130/255, blue: 246/255).opacity(0.4) : Color(red: 30/255, green: 35/255, blue: 48/255), lineWidth: 0.8)
                    )
                }

                // Completed Tab button
                Link(destination: URL(string: "dmx://downloads")!) {
                    HStack(spacing: 4) {
                        Text("COMPLETED (\(completedCount))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(entry.selectedTab == "completed" ? Color(red: 16/255, green: 185/255, blue: 129/255) : Color(red: 154/255, green: 163/255, blue: 181/255))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(entry.selectedTab == "completed" ? Color(red: 16/255, green: 185/255, blue: 129/255).opacity(0.18) : Color.clear)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(entry.selectedTab == "completed" ? Color(red: 16/255, green: 185/255, blue: 129/255).opacity(0.4) : Color(red: 30/255, green: 35/255, blue: 48/255), lineWidth: 0.8)
                    )
                }

                Spacer()

                // Total Speed
                if entry.totalSpeedBytesPerSec > 0 {
                    Text(XDMWidgetDataLoader.formatSpeed(entry.totalSpeedBytesPerSec))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 16/255, green: 185/255, blue: 129/255))
                }
            }

            Spacer()

            // Task List (up to 2 visible rows)
            let visibleTasks = Array(currentTabTasks.prefix(2))
            if !visibleTasks.isEmpty {
                VStack(spacing: 6) {
                    ForEach(visibleTasks) { task in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    // Category Tag
                                    Text(formatCategory(task))
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(Color(red: 139/255, green: 92/255, blue: 246/255))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color(red: 139/255, green: 92/255, blue: 246/255).opacity(0.18))
                                        .cornerRadius(4)

                                    // Filename
                                    Text(task.fileName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                        .foregroundColor(Color(red: 242/255, green: 244/255, blue: 248/255))
                                }

                                HStack(spacing: 6) {
                                    ProgressView(value: task.status == "completed" ? 1.0 : task.progress)
                                        .tint(task.status == "completed" ? Color(red: 16/255, green: 185/255, blue: 129/255) : Color(red: 59/255, green: 130/255, blue: 246/255))

                                    Text(task.status == "completed" ? XDMWidgetDataLoader.formatBytes(task.fileSizeBytes) : "\(Int(task.progress * 100))%")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(Color(red: 16/255, green: 185/255, blue: 129/255))
                                }
                            }

                            // Interactive per-item Action Button (Pause/Play/Open)
                            if task.status == "completed" {
                                Link(destination: URL(string: "dmx://open/\(task.id)")!) {
                                    Text("OPEN")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(Color(red: 16/255, green: 185/255, blue: 129/255))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Color(red: 16/255, green: 185/255, blue: 129/255).opacity(0.18))
                                        .cornerRadius(6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color(red: 16/255, green: 185/255, blue: 129/255).opacity(0.4), lineWidth: 0.8)
                                        )
                                }
                            } else {
                                let isPaused = task.status == "paused" || task.status == "failed"
                                Link(destination: URL(string: "dmx://toggle/\(task.id)")!) {
                                    Text(isPaused ? "▶" : "❚❚")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(isPaused ? Color(red: 16/255, green: 185/255, blue: 129/255) : Color(red: 59/255, green: 130/255, blue: 246/255))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background((isPaused ? Color(red: 16/255, green: 185/255, blue: 129/255) : Color(red: 59/255, green: 130/255, blue: 246/255)).opacity(0.18))
                                        .cornerRadius(6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke((isPaused ? Color(red: 16/255, green: 185/255, blue: 129/255) : Color(red: 59/255, green: 130/255, blue: 246/255)).opacity(0.4), lineWidth: 0.8)
                                        )
                                }
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 4) {
                    Text("ALL CLEAR")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(red: 16/255, green: 185/255, blue: 129/255))
                    Text(entry.selectedTab == "completed" ? "No completed downloads" : "No active downloads")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer()

            // Footer
            HStack {
                Text("\(activeCount) active · \(completedCount) completed")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)

                Spacer()

                if entry.availableStorageBytes >= 0 {
                    Text("\(XDMWidgetDataLoader.formatBytes(entry.availableStorageBytes)) free")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(red: 15/255, green: 17/255, blue: 23/255))
    }

    private func formatCategory(_ task: WidgetTaskSummaryItem) -> String {
        if task.isTorrent { return "TORRENT" }
        if task.isAppUpdate { return "UPDATE" }
        let cat = task.category.uppercased()
        return cat.isEmpty || cat == "OTHER" ? "FILE" : cat
    }
}
