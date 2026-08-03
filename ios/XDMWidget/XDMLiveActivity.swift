import ActivityKit
import WidgetKit
import SwiftUI

@available(iOS 16.1, *)
struct XDMDownloadAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var fileName: String
        var progress: Double
        var speedBytesPerSec: Int64
        var etaSeconds: Int
    }
    var taskId: String
}

@available(iOS 16.1, *)
class XDMLiveActivityManager {
    static let shared = XDMLiveActivityManager()

    func startActivity(taskId: String, fileName: String) {
        guard ActivityAuthorizationInfo().activitiesEnabled else { return }

        let attributes = XDMDownloadAttributes(taskId: taskId)
        let contentState = XDMDownloadAttributes.ContentState(
            fileName: fileName,
            progress: 0,
            speedBytesPerSec: 0,
            etaSeconds: 0
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                contentState: contentState,
                pushType: nil
            )
            print("XDM: Started Live Activity: \(activity.id)")
        } catch {
            print("XDM: Failed to start Live Activity: \(error)")
        }
    }

    func updateActivity(taskId: String, progress: Double, speed: Int64, eta: Int) {
        guard let activity = Activity<XDMDownloadAttributes>.activities.first(where: {
            $0.attributes.taskId == taskId
        }) else { return }

        let contentState = XDMDownloadAttributes.ContentState(
            fileName: activity.attributes.taskId,
            progress: progress,
            speedBytesPerSec: speed,
            etaSeconds: eta
        )

        Task {
            await activity.update(using: contentState)
        }
    }

    func endActivity(taskId: String) {
        guard let activity = Activity<XDMDownloadAttributes>.activities.first(where: {
            $0.attributes.taskId == taskId
        }) else { return }

        Task {
            await activity.end(dismissalPolicy: .after(.now + 5))
        }
    }
}

// MARK: - Live Activity Widget View

@available(iOS 16.1, *)
struct XDMLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: XDMDownloadAttributes.self) { context in
            // Lock Screen / Banner view
            VStack(spacing: 8) {
                HStack {
                    // Progress ring
                    ZStack {
                        Circle()
                            .stroke(Color.blue.opacity(0.2), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: context.state.progress)
                            .stroke(
                                AngularGradient(
                                    colors: [.blue.opacity(0.6), .blue],
                                    center: .center,
                                    startAngle: .degrees(-90),
                                    endAngle: .degrees(270)
                                ),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))

                        Text("\(Int(context.state.progress * 100))%")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.fileName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 8))
                                Text(formatSpeed(context.state.speedBytesPerSec))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            .foregroundStyle(.blue)

                            Text(XDMWidgetDataLoader.formatEta(context.state.etaSeconds))
                                .font(.system(size: 10))
                                .foregroundStyle(.gray)
                        }
                    }

                    Spacer()

                    // Downloaded / Total
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatSpeed(context.state.speedBytesPerSec))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                }

                // Linear progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.blue.opacity(0.7), .blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * context.state.progress)
                    }
                }
                .frame(height: 4)
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.06, green: 0.07, blue: 0.09))

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view
                DynamicIslandExpandedRegion(.leading) {
                    ZStack {
                        Circle()
                            .stroke(Color.blue.opacity(0.2), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: context.state.progress)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 32, height: 32)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.fileName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(formatSpeed(context.state.speedBytesPerSec))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.blue)
                            Text(XDMWidgetDataLoader.formatEta(context.state.etaSeconds))
                                .font(.system(size: 9))
                                .foregroundStyle(.gray)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(.blue)
                }

                // Progress bar across the bottom
                DynamicIslandExpandedRegion(.bottom) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule()
                                .fill(Color.blue)
                                .frame(width: geo.size.width * context.state.progress)
                        }
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

            } compactLeading: {
                ZStack {
                    Circle()
                        .stroke(Color.blue.opacity(0.3), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: context.state.progress)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 22, height: 22)
            }

            compactTrailing: {
                Text("\(Int(context.state.progress * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.blue)
            }

            minimal: {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.2))
                    Circle()
                        .trim(from: 0, to: context.state.progress)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 16, height: 16)
                }
                .frame(width: 22, height: 22)
            }
        }
    }

    private func formatSpeed(_ bytes: Int64) -> String {
        XDMWidgetDataLoader.formatSpeed(bytes)
    }
}
