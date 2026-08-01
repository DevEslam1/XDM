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
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)
                VStack(alignment: .leading) {
                    Text(context.state.fileName)
                        .font(.caption)
                        .lineLimit(1)
                    ProgressView(value: context.state.progress)
                        .tint(.blue)
                }
                Spacer()
                Text(formatSpeed(context.state.speedBytesPerSec))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.blue)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack {
                        Text(context.state.fileName)
                            .font(.caption)
                            .lineLimit(1)
                        ProgressView(value: context.state.progress)
                            .tint(.blue)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(formatSpeed(context.state.speedBytesPerSec))
                        .font(.caption2)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))%")
                    .font(.caption2)
            } minimal: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)
            }
        }
    }

    private func formatSpeed(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        return mb >= 1 ? String(format: "%.1f MB/s", mb) : String(format: "%.0f KB/s", Double(bytes) / 1024)
    }
}
