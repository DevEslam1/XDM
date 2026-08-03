import SwiftUI
import WidgetKit

struct XDMMediumWidgetView: View {
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
            // ── Header: Tabs + Speed ──
            HStack(spacing: 6) {
                // Tab pills
                HStack(spacing: 4) {
                    TabPill(
                        label: "DL (\(activeCount))",
                        isActive: entry.selectedTab != "completed",
                        color: .blue,
                        url: "dmx://downloads"
                    )
                    TabPill(
                        label: "DONE (\(completedCount))",
                        isActive: entry.selectedTab == "completed",
                        color: .green,
                        url: "dmx://downloads"
                    )
                }

                Spacer()

                // Total speed badge
                if entry.totalSpeedBytesPerSec > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                        Text(XDMWidgetDataLoader.formatSpeed(entry.totalSpeedBytesPerSec))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.green.opacity(0.3), lineWidth: 0.5))
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

            Spacer(minLength: 0)

            // ── Task Rows (up to 2) ──
            let visibleTasks = Array(currentTabTasks.prefix(2))
            if !visibleTasks.isEmpty {
                VStack(spacing: 5) {
                    ForEach(visibleTasks) { task in
                        MediumTaskRow(task: task)
                    }
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "tray")
                        .font(.system(size: 20))
                        .foregroundStyle(.gray.opacity(0.5))
                    Text(entry.selectedTab == "completed" ? "No completed downloads" : "No active downloads")
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 0)

            // ── Footer: Storage + Wifi ──
            HStack {
                if entry.totalActiveCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(.blue).frame(width: 4, height: 4)
                        Text("\(entry.totalActiveCount) active")
                            .font(.system(size: 8))
                            .foregroundStyle(.gray)
                    }
                }

                Spacer()

                if entry.isOnWifi {
                    Image(systemName: "wifi")
                        .font(.system(size: 8))
                        .foregroundStyle(.blue.opacity(0.6))
                }

                if entry.availableStorageBytes >= 0 {
                    Text("\(XDMWidgetDataLoader.formatBytes(entry.availableStorageBytes)) free")
                        .font(.system(size: 8))
                        .foregroundStyle(entry.isStorageLow ? .orange : .gray)
                }
            }
        }
        .padding(12)
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

// MARK: - Task Row Component

struct MediumTaskRow: View {
    let task: WidgetTaskSummaryItem

    var body: some View {
        HStack(spacing: 8) {
            // Status dot
            Circle()
                .fill(task.statusColor)
                .frame(width: 6, height: 6)
                .shadow(color: task.statusColor.opacity(0.6), radius: 3)

            VStack(alignment: .leading, spacing: 3) {
                // Name + category
                HStack(spacing: 4) {
                    Image(systemName: task.categoryIcon)
                        .font(.system(size: 8))
                        .foregroundStyle(task.categoryColor)

                    Text(task.fileName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    // Percentage
                    Text(task.isCompleted ? "100%" : "\(Int(task.progress * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(task.statusColor)
                }

                // Progress bar + speed/ETA
                HStack(spacing: 6) {
                    // Gradient progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [task.statusColor.opacity(0.7), task.statusColor],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * (task.isCompleted ? 1.0 : task.progress))
                        }
                    }
                    .frame(height: 4)

                    // Speed or ETA
                    if task.status == "downloading" {
                        Text(XDMWidgetDataLoader.formatSpeed(task.speedBytesPerSec))
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(.blue)
                            .frame(width: 52, alignment: .trailing)

                        Text(XDMWidgetDataLoader.formatEta(task.etaSeconds))
                            .font(.system(size: 8))
                            .foregroundStyle(.gray)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            // Action button
            TaskActionButton(task: task, size: .small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}

// MARK: - Tab Pill

struct TabPill: View {
    let label: String
    let isActive: Bool
    let color: Color
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isActive ? color : .gray)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isActive ? color.opacity(0.15) : Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isActive ? color.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 0.6)
                )
        }
    }
}

// MARK: - Action Button

struct TaskActionButton: View {
    let task: WidgetTaskSummaryItem
    var size: ButtonSize = .medium

    enum ButtonSize { case small, medium }

    var body: some View {
        let isSmall = size == .small
        let iconSize: CGFloat = isSmall ? 9 : 11
        let padding: CGFloat = isSmall ? 5 : 7

        if task.isCompleted {
            Link(destination: URL(string: "dmx://open/\(task.id)")!) {
                Image(systemName: "folder")
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundStyle(.green)
                    .frame(width: padding * 2 + iconSize, height: padding * 2 + iconSize)
                    .background(Color.green.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: isSmall ? 6 : 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: isSmall ? 6 : 8)
                            .stroke(Color.green.opacity(0.3), lineWidth: 0.5)
                    )
            }
        } else if task.status == "downloading" || task.status == "queued" {
            Link(destination: URL(string: "dmx://toggle/\(task.id)")!) {
                Image(systemName: "pause.fill")
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundStyle(.blue)
                    .frame(width: padding * 2 + iconSize, height: padding * 2 + iconSize)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: isSmall ? 6 : 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: isSmall ? 6 : 8)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 0.5)
                    )
            }
        } else {
            Link(destination: URL(string: "dmx://toggle/\(task.id)")!) {
                Image(systemName: "play.fill")
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundStyle(.green)
                    .frame(width: padding * 2 + iconSize, height: padding * 2 + iconSize)
                    .background(Color.green.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: isSmall ? 6 : 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: isSmall ? 6 : 8)
                            .stroke(Color.green.opacity(0.3), lineWidth: 0.5)
                    )
            }
        }
    }
}
