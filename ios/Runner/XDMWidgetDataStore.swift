import Foundation

/// Service for writing shared download metrics to App Group shared container for iOS Widget consumption.
public class XDMWidgetDataStore: NSObject {
    public static let shared = XDMWidgetDataStore()
    private let appGroupID = "group.com.dmx.app"

    /// Updates active download metrics in the shared App Group container.
    public func updateWidgetData(
        activeCount: Int,
        speedBytesPerSec: Int64,
        completedCount: Int,
        progress: Double = 0.0,
        topFileName: String = ""
    ) {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupID) else {
            print("XDM Widget DataStore Warning: Could not open App Group '\(appGroupID)'")
            return
        }

        let dict: [String: Any] = [
            "activeCount": activeCount,
            "speedBytesPerSec": speedBytesPerSec,
            "completedCount": completedCount,
            "progress": progress,
            "topFileName": topFileName,
            "updatedAt": Date().timeIntervalSince1970
        ]

        if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
           let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let fileURL = containerURL.appendingPathComponent("xdm_widget_stats.json")
            try? data.write(to: fileURL)
        }

        sharedDefaults.set(activeCount, forKey: "xdm_active_count")
        sharedDefaults.set(speedBytesPerSec, forKey: "xdm_speed")
        sharedDefaults.set(completedCount, forKey: "xdm_completed_count")
        sharedDefaults.set(progress, forKey: "xdm_progress")
        sharedDefaults.set(topFileName, forKey: "xdm_top_file_name")
        sharedDefaults.synchronize()
    }
}
