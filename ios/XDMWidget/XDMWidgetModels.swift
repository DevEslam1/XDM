import WidgetKit
import Foundation
import SwiftUI

// MARK: - Data Models

struct WidgetTaskSummaryItem: Identifiable, Codable, Hashable {
    let id: String
    let fileName: String
    let status: String // queued | downloading | paused | completed | failed | seeding
    let progress: Double
    let speedBytesPerSec: Int64
    let etaSeconds: Int?
    let fileSizeBytes: Int64
    let downloadedBytes: Int64
    let category: String
    let isTorrent: Bool
    let isAppUpdate: Bool

    var isActive: Bool { status == "downloading" || status == "seeding" }
    var isFailed: Bool { status == "failed" }
    var isPaused: Bool { status == "paused" }
    var isQueued: Bool { status == "queued" }
    var isCompleted: Bool { status == "completed" }

    /// Status dot color for live indicator
    var statusColor: Color {
        switch status {
        case "downloading": return .blue
        case "seeding":     return .green
        case "paused":      return .orange
        case "queued":      return .purple
        case "failed":      return .red
        case "completed":   return .green
        default:            return .gray
        }
    }

    /// Category badge color
    var categoryColor: Color {
        switch category.lowercased() {
        case "video":    return .blue
        case "audio":    return .green
        case "document": return .orange
        case "archive":  return .purple
        case "apk":      return .pink
        case "torrent":  return .purple
        default:         return .gray
        }
    }

    /// Category icon name (SF Symbol)
    var categoryIcon: String {
        switch category.lowercased() {
        case "video":    return "movie"
        case "audio":    return "waveform"
        case "document": return "doc.text"
        case "archive":  return "shippingbox"
        case "apk":      return "iphone"
        default:         return "doc"
        }
    }
}

struct XDMWidgetEntry: TimelineEntry {
    let date: Date
    let tasks: [WidgetTaskSummaryItem]
    let totalActiveCount: Int
    let totalSpeedBytesPerSec: Int64
    let completedTodayCount: Int
    let failedCount: Int
    let availableStorageBytes: Int64
    let isOnWifi: Bool
    let selectedTab: String // "downloading" or "completed"

    /// Overall progress across all active tasks
    var overallProgress: Double {
        let active = tasks.filter { $0.status == "downloading" }
        guard !active.isEmpty else { return 0 }
        return active.map(\.progress).reduce(0, +) / Double(active.count)
    }

    /// Primary task to feature (first downloading or first in list)
    var featuredTask: WidgetTaskSummaryItem? {
        tasks.first { $0.status == "downloading" } ?? tasks.first
    }

    /// Whether storage is critically low (< 500 MB)
    var isStorageLow: Bool {
        availableStorageBytes >= 0 && availableStorageBytes < 500 * 1024 * 1024
    }

    var hasFailures: Bool { failedCount > 0 }
}

// MARK: - Shared Data Loader

struct XDMWidgetDataLoader {
    static let appGroupId = "group.com.dmx.app"
    static let statsFileName = "xdm_widget_stats.json"

    static func loadStats(tab: String = "downloading") -> XDMWidgetEntry? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { return nil }

        let fileURL = containerURL.appendingPathComponent(statsFileName)

        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let activeCount = json["totalActiveCount"] as? Int ?? json["activeCount"] as? Int ?? 0
        let speed = json["totalSpeedBytesPerSec"] as? Int64 ?? json["speedBytesPerSec"] as? Int64 ?? 0
        let completed = json["completedTodayCount"] as? Int ?? json["completedCount"] as? Int ?? 0
        let failed = json["failedCount"] as? Int ?? 0
        let storage = json["availableStorageBytes"] as? Int64 ?? -1
        let wifi = json["isOnWifi"] as? Bool ?? false
        let updatedAt = json["updatedAt"] as? TimeInterval ?? 0

        // Stale data check: if older than 15 minutes, mark speed as 0
        let isStale = Date().timeIntervalSince1970 - updatedAt > 900

        var parsedTasks: [WidgetTaskSummaryItem] = []
        if let rawTasks = json["tasks"] as? [[String: Any]] {
            for t in rawTasks {
                let id = t["id"] as? String ?? UUID().uuidString
                let fileName = t["fileName"] as? String ?? "File"
                let status = t["status"] as? String ?? "downloading"
                let progress = t["progress"] as? Double ?? 0.0
                let taskSpeed = t["speedBytesPerSec"] as? Int64 ?? 0
                let eta = t["etaSeconds"] as? Int
                let fileSize = t["fileSizeBytes"] as? Int64 ?? 0
                let downloaded = t["downloadedBytes"] as? Int64 ?? 0
                let category = t["category"] as? String ?? "File"
                let isTorrent = t["isTorrent"] as? Bool ?? false
                let isAppUpdate = t["isAppUpdate"] as? Bool ?? false

                parsedTasks.append(
                    WidgetTaskSummaryItem(
                        id: id,
                        fileName: fileName,
                        status: isStale && status == "downloading" ? "paused" : status,
                        progress: progress,
                        speedBytesPerSec: isStale ? 0 : taskSpeed,
                        etaSeconds: isStale ? nil : eta,
                        fileSizeBytes: fileSize,
                        downloadedBytes: downloaded,
                        category: category,
                        isTorrent: isTorrent,
                        isAppUpdate: isAppUpdate
                    )
                )
            }
        }

        return XDMWidgetEntry(
            date: Date(),
            tasks: parsedTasks,
            totalActiveCount: isStale ? 0 : activeCount,
            totalSpeedBytesPerSec: isStale ? 0 : speed,
            completedTodayCount: completed,
            failedCount: failed,
            availableStorageBytes: storage,
            isOnWifi: wifi,
            selectedTab: tab
        )
    }

    // MARK: - Formatting Helpers

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

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        return unitIndex == 0
            ? "\(Int(value)) \(units[unitIndex])"
            : String(format: "%.1f %@", value, units[unitIndex])
    }

    static func formatEta(_ etaSeconds: Int?) -> String {
        guard let seconds = etaSeconds, seconds > 0 else { return "--" }
        if seconds < 10 { return "Almost done" }
        if seconds < 60 { return "\(seconds)s left" }
        if seconds < 300 { return "~\(seconds / 60)m left" }
        if seconds < 3600 {
            let m = seconds / 60
            let s = seconds % 60
            return "~\(m)m \(s)s"
        }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return m == 0 ? "~\(h)h" : "~\(h)h \(m)m"
    }

    /// Smart speed trend indicator based on current speed
    static func speedTrend(_ task: WidgetTaskSummaryItem) -> (icon: String, color: Color) {
        let speed = task.speedBytesPerSec
        if speed <= 0 { return ("pause.circle", .gray) }
        if speed > 10 * 1024 * 1024 { return ("bolt.fill", .green) }
        if speed > 1 * 1024 * 1024 { return ("arrow.down.circle.fill", .blue) }
        if speed > 100 * 1024 { return ("arrow.down.right.circle.fill", .orange) }
        return ("arrow.down.slow", .red)
    }
}
