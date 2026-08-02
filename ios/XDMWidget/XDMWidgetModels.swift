import WidgetKit
import Foundation

// MARK: - Timeline Entry
struct XDMWidgetEntry: TimelineEntry {
    let date: Date
    let activeCount: Int
    let speedBytesPerSec: Int64
    let completedCount: Int
    let totalDownloads: Int
    let topFileName: String
    let topFileProgress: Double
    let isDownloading: Bool
}

// MARK: - Shared Data Loader
struct XDMWidgetDataLoader {
    static let appGroupId = "group.com.dmx.app"
    static let statsFileName = "xdm_widget_stats.json"

    static func loadStats() -> XDMWidgetEntry? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { return nil }

        let fileURL = containerURL.appendingPathComponent(statsFileName)

        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let activeCount = json["activeCount"] as? Int ?? 0
        let speed = json["speedBytesPerSec"] as? Int64 ?? 0
        let completed = json["completedCount"] as? Int ?? 0
        let total = json["totalDownloads"] as? Int ?? 0
        let topFile = json["topFileName"] as? String ?? ""
        let progress = json["progress"] as? Double ?? 0.0
        let updatedAt = json["updatedAt"] as? TimeInterval ?? 0

        // Stale data check: if older than 10 minutes, show as idle
        let isStale = Date().timeIntervalSince1970 - updatedAt > 600

        return XDMWidgetEntry(
            date: Date(),
            activeCount: isStale ? 0 : activeCount,
            speedBytesPerSec: isStale ? 0 : speed,
            completedCount: completed,
            totalDownloads: total,
            topFileName: topFile,
            topFileProgress: isStale ? 0 : progress,
            isDownloading: !isStale && activeCount > 0
        )
    }

    static func formatSpeed(_ bytesPerSec: Int64) -> String {
        if bytesPerSec <= 0 { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = Double(bytesPerSec)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        return unitIndex == 0
            ? "\(Int(value)) \(units[unitIndex])"
            : String(format: "%.1f %@", value, units[unitIndex])
    }
}
