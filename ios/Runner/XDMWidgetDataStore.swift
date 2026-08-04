import Foundation
import WidgetKit

/// Service for writing shared download metrics to App Group shared container for iOS Widget consumption.
public class XDMWidgetDataStore: NSObject {
    public static let shared = XDMWidgetDataStore()
    private let appGroupID = "group.com.dmx.app"
    private let statsFileName = "xdm_widget_stats.json"

    /// Saves the complete JSON dashboard payload pushed by the Flutter engine
    /// to the App Group shared container and reloads WidgetKit timelines.
    public func saveDashboardJson(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else { return }

        let fileURL = containerURL.appendingPathComponent(statsFileName)
        try? data.write(to: fileURL)

        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Legacy overload for backward compatibility.
    public func updateWidgetData(
        activeCount: Int,
        speedBytesPerSec: Int64,
        completedCount: Int,
        progress: Double = 0.0,
        topFileName: String = ""
    ) {
        let dict: [String: Any] = [
            "totalActiveCount": activeCount,
            "totalSpeedBytesPerSec": speedBytesPerSec,
            "completedTodayCount": completedCount,
            "tasks": [
                [
                    "id": "top_task",
                    "fileName": topFileName,
                    "status": activeCount > 0 ? "downloading" : "completed",
                    "progress": progress,
                    "speedBytesPerSec": speedBytesPerSec,
                    "fileSizeBytes": Int64(0),
                    "downloadedBytes": Int64(0),
                    "category": "File",
                    "isTorrent": false,
                    "isAppUpdate": false
                ]
            ],
            "updatedAt": Date().timeIntervalSince1970
        ]

        if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
           let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let fileURL = containerURL.appendingPathComponent(statsFileName)
            try? data.write(to: fileURL)
        }

        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    public func getFreeDiskSpace() -> Int64 {
        // FIX(A-2): Query the App Group container volume first, fallback to NSHomeDirectory()
        let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        let fileURL = containerURL ?? URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return capacity
            }
        } catch {
            print("Failed to fetch free disk space: \(error)")
        }
        return -1
    }
}

