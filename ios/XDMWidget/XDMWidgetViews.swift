import SwiftUI
import WidgetKit

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
        VStack(alignment: .leading, spacing: 6) {
            // ── Header ──
            HStack(spacing: 6) {
                // Brand
                Text("XDM")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Spacer()

                // Tab pills
                TabPill(label: "DL (\(activeCount))", isActive: entry.selectedTab != "completed", color: .blue, url: "dmx://downloads")
                TabPill(label: "DONE (\(completedCount))", isActive: entry.selectedTab == "completed", color: .green, url: "dmx://downloads")

                // Speed
                if entry.totalSpeedBytesPerSec > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                        Text(XDMWidgetDataLoader.formatSpeed(entry.totalSpeedBytesPerSec))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.08))
                    .clipShape(Capsule())
                }
            }

            // ── Failure banner ──
            if entry.hasFailures && entry.selectedTab != "completed" {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                    Text("\(entry.failedCount) download\(entry.failedCount == 1 ? "" : "s") failed")
                        .font(.system(size: 8, weight: .bold))
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // ── Storage warning ──
            if entry.isStorageLow {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 8))
                    Text("Low storage: \(XDMWidgetDataLoader.formatBytes(entry.availableStorageBytes)) free")
                        .font(.system(size: 8, weight: .bold))
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Spacer(minLength: 2)

            // ── Task Rows (up to 5) ──
            let visibleTasks = Array(currentTabTasks.prefix(5))
            if !visibleTasks.isEmpty {
                VStack(spacing: 4) {
                    ForEach(visibleTasks) { task in
                        LargeTaskRow(task: task)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 24))
                        .foregroundStyle(.gray.opacity(0.4))
                    Text(entry.selectedTab == "completed" ? "No completed downloads" : "No active downloads")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }

            Spacer(minLength: 2)

            // ── Quick Actions ──
            HStack(spacing: 6) {
                Link(destination: URL(string: "dmx://pause_all")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text("PAUSE ALL")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 0.6)
                    )
                }

                Link(destination: URL(string: "dmx://resume_all")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text("RESUME ALL")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.green.opacity(0.3), lineWidth: 0.6)
                    )
                }
            }

            // ── Footer ──
            HStack {
                if entry.totalActiveCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(.blue).frame(width: 4, height: 4)
                        Text("\(entry.totalActiveCount) active · \(entry.completedTodayCount) done today")
                            .font(.system(size: 7))
                            .foregroundStyle(.gray)
                    }
                }
                Spacer()
                if entry.availableStorageBytes >= 0 {
                    Text("\(XDMWidgetDataLoader.formatBytes(entry.availableStorageBytes)) free")
                        .font(.system(size: 7))
                        .foregroundStyle(entry.isStorageLow ? .orange : .gray)
                }
            }
        }
        .padding(13)
        .background(widgetBackground)
    }

    private var widgetBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(red: 0.06, green: 0.07, blue: 0.09))
            RoundedRectangle(cornerRadius: 22)
                .stroke(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }
}

// MARK: - Large Task Row

struct LargeTaskRow: View {
    let task: WidgetTaskSummaryItem

    var body: some View {
        HStack(spacing: 7) {
            // Status dot
            Circle()
                .fill(task.statusColor)
                .frame(width: 5, height: 5)
                .shadow(color: task.statusColor.opacity(0.5), radius: 2)

            VStack(alignment: .leading, spacing: 2) {
                // Row 1: category + name + percent
                HStack(spacing: 4) {
                    Image(systemName: task.categoryIcon)
                        .font(.system(size: 8))
                        .foregroundStyle(task.categoryColor)

                    Text(task.fileName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 2)

                    Text(task.isCompleted ? "100%" : "\(Int(task.progress * 100))%")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(task.statusColor)
                }

                // Row 2: progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [task.statusColor.opacity(0.6), task.statusColor],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * (task.isCompleted ? 1.0 : task.progress))
                    }
                }
                .frame(height: 3)

                // Row 3: speed + ETA (only for downloading)
                if task.status == "downloading" {
                    HStack(spacing: 8) {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 6))
                            Text(XDMWidgetDataLoader.formatSpeed(task.speedBytesPerSec))
                                .font(.system(size: 7, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.blue)

                        Text(XDMWidgetDataLoader.formatEta(task.etaSeconds))
                            .font(.system(size: 7))
                            .foregroundStyle(.gray)

                        Spacer()

                        Text(XDMWidgetDataLoader.formatBytes(task.downloadedBytes) + " / " + XDMWidgetDataLoader.formatBytes(task.fileSizeBytes))
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundStyle(.gray)
                    }
                }
            }

            // Action button
            TaskActionButton(task: task, size: .small)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
        )
    }
}
