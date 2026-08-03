import SwiftUI
import WidgetKit

struct XDMSmallWidgetView: View {
    var entry: XDMWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var task: WidgetTaskSummaryItem? { entry.featuredTask }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row: brand + speed
            HStack {
                Text("XDM")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Spacer()

                if entry.totalSpeedBytesPerSec > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.green)
                        Text(XDMWidgetDataLoader.formatSpeed(entry.totalSpeedBytesPerSec))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(.bottom, 8)

            Spacer(minLength: 0)

            if let task = task {
                // Category badge + progress ring
                HStack(alignment: .center, spacing: 10) {
                    // Progress ring
                    ZStack {
                        // Background ring
                        Circle()
                            .stroke(Color.white.opacity(0.08), lineWidth: 5)

                        // Progress ring
                        Circle()
                            .trim(from: 0, to: task.isCompleted ? 1.0 : task.progress)
                            .stroke(
                                AngularGradient(
                                    colors: [
                                        task.statusColor.opacity(0.7),
                                        task.statusColor
                                    ],
                                    center: .center,
                                    startAngle: .degrees(-90),
                                    endAngle: .degrees(270)
                                ),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))

                        // Center content
                        VStack(spacing: 1) {
                            Text(task.isCompleted ? "100%" : "\(Int(task.progress * 100))%")
                                .font(.system(size: 13, weight: .black, design: .monospaced))
                                .foregroundStyle(.white)

                            Text(task.isCompleted ? "DONE" : task.status.uppercased().prefix(4).uppercased())
                                .font(.system(size: 6, weight: .bold))
                                .foregroundStyle(task.statusColor)
                        }
                    }
                    .frame(width: 56, height: 56)

                    // Right side: file info
                    VStack(alignment: .leading, spacing: 3) {
                        // Category chip
                        HStack(spacing: 3) {
                            Image(systemName: task.categoryIcon)
                                .font(.system(size: 8))
                            Text(task.category.uppercased().prefix(5).uppercased())
                                .font(.system(size: 7, weight: .bold))
                        }
                        .foregroundStyle(task.categoryColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(task.categoryColor.opacity(0.15))
                        .clipShape(Capsule())

                        // File name
                        Text(task.fileName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        // Size info
                        Text(XDMWidgetDataLoader.formatBytes(task.fileSizeBytes))
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(.gray)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // Empty state
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.green.opacity(0.8))
                    Text("ALL CLEAR")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.green)
                    Text("No active downloads")
                        .font(.system(size: 9))
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)

            // Footer: active count + storage
            HStack {
                if entry.totalActiveCount > 0 {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(.blue)
                            .frame(width: 5, height: 5)
                        Text("\(entry.totalActiveCount) active")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.gray)
                    }
                }

                Spacer()

                if entry.availableStorageBytes >= 0 {
                    Text("\(XDMWidgetDataLoader.formatBytes(entry.availableStorageBytes)) free")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(entry.isStorageLow ? .orange : .gray)
                }
            }
            .padding(.top, 8)
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
