import SwiftUI
import WidgetKit

// MARK: - Large Widget View (.systemLarge)
struct XDMWidgetLargeView: View {
    var entry: XDMWidgetEntry

    private var currentTabTasks: [WidgetTaskSummaryItem] {
        if entry.selectedTab == "completed" {
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
        VStack(alignment: .leading, spacing: 8) {
            // Header Bar
            HStack {
                HStack(spacing: 6) {
                    Text("XDM SIGNAL DECK")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 59/255, green: 130/255, blue: 246/255))
                }

                Spacer()

                if entry.totalSpeedBytesPerSec > 0 {
                    Text(XDMWidgetDataLoader.formatSpeed(entry.totalSpeedBytesPerSec))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 16/255, green: 185/255, blue: 129/255))
                }
            }

            // Failure Banner
            if entry.failedCount > 0 && entry.selectedTab != "completed" {
                HStack {
                    Text("⚠️ \(entry.failedCount) download\(entry.failedCount == 1 ? "" : "s") failed")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(red: 239/255, green: 68/255, blue: 68/255))
                .cornerRadius(4)
            }

            // 2-Tab Header Bar
            HStack(spacing: 8) {
                // Downloading Tab button
                Link(destination: URL(string: "dmx://downloads")!) {
                    HStack(spacing: 4) {
                        Text("DOWNLOADING (\(activeCount))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(entry.selectedTab != "completed" ? Color(red: 59/255, green: 130/255, blue: 246/255) : Color(red: 154/255, green: 163/255, blue: 181/255))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(entry.selectedTab == "completed" ? Color(red: 16/255, green: 185/255, blue: 129/255).opacity(0.18) : Color.clear)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(entry.selectedTab == "completed" ? Color(red: 16/255, green: 185/255, blue: 129/255).opacity(0.4) : Color(red: 30/255, green: 35/255, blue: 48/255), lineWidth: 0.8)
                    )
                }

                Spacer()
            }

            Spacer()

            // Up to 5 task rows
            let visibleTasks = Array(currentTabTasks.prefix(5))
            if !visibleTasks.isEmpty {
                VStack(spacing: 8) {
                    ForEach(visibleTasks) { task in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(formatCategory(task))
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(Color(red: 139/255, green: 92/255, blue: 246/255))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color(red: 139/255, green: 92/255, blue: 246/255).opacity(0.18))
                                        .cornerRadius(4)

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
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color(red: 16/255, green: 185/255, blue: 129/255))
                    Text(entry.selectedTab == "completed" ? "No completed downloads" : "No active downloads")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer()

            // Quick Actions Bar
            HStack(spacing: 8) {
                Link(destination: URL(string: "dmx://pause_all")!) {
                    HStack {
                        Spacer()
                        Text("❚❚ PAUSE ALL")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(red: 59/255, green: 130/255, blue: 246/255))
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .background(Color(red: 59/255, green: 130/255, blue: 246/255).opacity(0.18))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(red: 59/255, green: 130/255, blue: 246/255).opacity(0.4), lineWidth: 0.8)
                    )
                }

                Link(destination: URL(string: "dmx://resume_all")!) {
                    HStack {
                        Spacer()
                        Text("▶ RESUME ALL")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(red: 16/255, green: 185/255, blue: 129/255))
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .background(Color(red: 16/255, green: 185/255, blue: 129/255).opacity(0.18))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(red: 16/255, green: 185/255, blue: 129/255).opacity(0.4), lineWidth: 0.8)
                    )
                }
            }
        }
        .padding(13)
        .background(Color(red: 15/255, green: 17/255, blue: 23/255))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
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
