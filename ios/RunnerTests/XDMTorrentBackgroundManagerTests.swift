import XCTest
@testable import Runner

final class XDMTorrentBackgroundManagerTests: XCTestCase {

    var manager: XDMTorrentBackgroundManager!

    override func setUp() {
        super.setUp()
        manager = XDMTorrentBackgroundManager.shared
    }

    func testSaveAndLoadResumeData() {
        let testData = "test-resume-data".data(using: .utf8)!
        let torrentId = 42

        manager.saveTorrentResumeData(torrentId: torrentId, data: testData)
        let loaded = manager.loadTorrentResumeData(torrentId: torrentId)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, testData)

        // Cleanup
        manager.clearTorrentResumeData(torrentId: torrentId)
    }

    func testClearResumeData() {
        let testData = "test-data".data(using: .utf8)!
        let torrentId = 99

        manager.saveTorrentResumeData(torrentId: torrentId, data: testData)
        manager.clearTorrentResumeData(torrentId: torrentId)

        let loaded = manager.loadTorrentResumeData(torrentId: torrentId)
        XCTAssertNil(loaded)
    }

    func testActiveTorrentIdsPersistence() {
        let ids = [1, 2, 3, 5, 8]
        UserDefaults.standard.set(ids, forKey: "xdm_active_torrent_ids")

        let loaded = manager.getActiveTorrentIds()
        XCTAssertEqual(loaded, ids)

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "xdm_active_torrent_ids")
    }

    func testAppDidEnterBackgroundSavesState() {
        var pausedCalled = false
        manager.onTorrentsPaused = { pausedCalled = true }

        manager.appDidEnterBackground(activeTorrentIds: [1, 2, 3])

        XCTAssertTrue(pausedCalled)
        XCTAssertEqual(manager.getActiveTorrentIds(), [1, 2, 3])

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "xdm_active_torrent_ids")
    }

    func testAppWillEnterForegroundResumes() {
        var resumedCalled = false
        manager.onTorrentsResumed = { resumedCalled = true }

        manager.appWillEnterForeground()

        XCTAssertTrue(resumedCalled)
    }
}
