import WidgetKit
import SwiftUI

// MARK: - Timeline Provider
struct XDMTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> XDMWidgetEntry {
        XDMWidgetEntry(
            date: Date(),
            activeCount: 2,
            speedBytesPerSec: 5_242_880,
            completedCount: 12,
            progress: 0.65,
            topFileName: "ubuntu-24.04.iso"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (XDMWidgetEntry) -> Void) {
        let entry = loadCurrentData() ?? placeholder(in: context)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<XDMWidgetEntry>) -> Void) {
        let entry = loadCurrentData() ?? placeholder(in: context)
        // Refresh every 5 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func loadCurrentData() -> XDMWidgetEntry? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.dmx.app"
        ) else { return nil }

        let fileURL = containerURL.appendingPathComponent("xdm_widget_stats.json")
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let activeCount = json["activeCount"] as? Int ?? 0
        let speed = json["speedBytesPerSec"] as? Int64 ?? 0
        let completed = json["completedCount"] as? Int ?? 0
        let progress = json["progress"] as? Double ?? 0.0
        let topFile = json["topFileName"] as? String ?? ""

        return XDMWidgetEntry(
            date: Date(),
            activeCount: activeCount,
            speedBytesPerSec: speed,
            completedCount: completed,
            progress: progress,
            topFileName: topFile
        )
    }
}

// MARK: - Entry
struct XDMWidgetEntry: TimelineEntry {
    let date: Date
    let activeCount: Int
    let speedBytesPerSec: Int64
    let completedCount: Int
    let progress: Double
    let topFileName: String
}
