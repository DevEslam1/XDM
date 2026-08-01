import XCTest
@testable import Runner

final class XDMWidgetDataStoreTests: XCTestCase {

    var store: XDMWidgetDataStore!

    override func setUp() {
        super.setUp()
        store = XDMWidgetDataStore.shared
    }

    func testUpdateWidgetData() {
        store.updateWidgetData(
            activeCount: 3,
            speedBytesPerSec: 5_242_880,
            completedCount: 15,
            progress: 0.65,
            topFileName: "test-file.iso"
        )

        // Verify UserDefaults if suite opens
        if let sharedDefaults = UserDefaults(suiteName: "group.com.dmx.app") {
            XCTAssertEqual(sharedDefaults.integer(forKey: "xdm_active_count"), 3)
            XCTAssertEqual(sharedDefaults.integer(forKey: "xdm_speed"), 5_242_880)
            XCTAssertEqual(sharedDefaults.integer(forKey: "xdm_completed_count"), 15)
        }
    }

    func testUpdateWidgetDataWritesJSONFile() {
        store.updateWidgetData(
            activeCount: 1,
            speedBytesPerSec: 1_048_576,
            completedCount: 5,
            progress: 0.3,
            topFileName: "video.mp4"
        )

        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.dmx.app"
        ) {
            let fileURL = containerURL.appendingPathComponent("xdm_widget_stats.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

            if let data = try? Data(contentsOf: fileURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                XCTAssertEqual(json["activeCount"] as? Int, 1)
                XCTAssertEqual(json["topFileName"] as? String, "video.mp4")
            }
        }
    }

    func testUpdateWidgetDataWithZeroValues() {
        store.updateWidgetData(
            activeCount: 0,
            speedBytesPerSec: 0,
            completedCount: 0,
            progress: 0.0,
            topFileName: ""
        )

        if let sharedDefaults = UserDefaults(suiteName: "group.com.dmx.app") {
            XCTAssertEqual(sharedDefaults.integer(forKey: "xdm_active_count"), 0)
            XCTAssertEqual(sharedDefaults.integer(forKey: "xdm_speed"), 0)
        }
    }
}
