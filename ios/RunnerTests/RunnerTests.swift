import XCTest
@testable import Runner

final class XDMBackgroundDownloadManagerTests: XCTestCase {

    var manager: XDMBackgroundDownloadManager!

    override func setUp() {
        super.setUp()
        manager = XDMBackgroundDownloadManager.shared
    }

    override func tearDown() {
        // Clean up any active tasks
        manager.cancelDownload(taskId: "test-task-1")
        super.tearDown()
    }

    // MARK: - Start Download Tests

    func testStartDownloadWithValidURL() {
        let expectation = expectation(description: "Download started")
        let taskId = "test-start-\(UUID().uuidString)"

        manager.onProgressUpdate = { id, written, total in
            if id == taskId {
                expectation.fulfill()
            }
        }

        manager.startDownload(
            taskId: taskId,
            urlStr: "https://httpbin.org/bytes/1024",
            destinationPath: NSTemporaryDirectory() + "test_download.bin"
        )

        waitForExpectations(timeout: 30)
        manager.cancelDownload(taskId: taskId)
    }

    func testStartDownloadWithInvalidURL() {
        let expectation = expectation(description: "Download failed")
        let taskId = "test-invalid-\(UUID().uuidString)"

        manager.onTaskFailed = { id, error in
            if id == taskId {
                XCTAssertTrue(error.contains("Invalid URL") || error.contains("invalid"))
                expectation.fulfill()
            }
        }

        manager.startDownload(
            taskId: taskId,
            urlStr: "not-a-valid-url",
            destinationPath: NSTemporaryDirectory() + "test.bin"
        )

        waitForExpectations(timeout: 5)
    }

    // MARK: - Pause/Resume Tests

    func testPauseAndResumeDownload() {
        let taskId = "test-pause-\(UUID().uuidString)"
        let urlStr = "https://httpbin.org/bytes/1048576" // 1MB
        let destPath = NSTemporaryDirectory() + "test_pause.bin"

        // Start
        manager.startDownload(taskId: taskId, urlStr: urlStr, destinationPath: destPath)

        // Pause after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.manager.pauseDownload(taskId: taskId)

            // Verify resume data was saved
            let resumeData = UserDefaults.standard.data(forKey: "xdm_resume_\(taskId)")
            XCTAssertNotNil(resumeData, "Resume data should be saved on pause")

            // Resume
            self.manager.resumeDownload(taskId: taskId, urlStr: urlStr, destinationPath: destPath)
        }

        // Wait for completion
        let expectation = expectation(description: "Download completed after resume")
        manager.onTaskComplete = { id, path in
            if id == taskId {
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 60)
        manager.cancelDownload(taskId: taskId)
    }

    // MARK: - Cancel Tests

    func testCancelDownload() {
        let taskId = "test-cancel-\(UUID().uuidString)"

        manager.startDownload(
            taskId: taskId,
            urlStr: "https://httpbin.org/bytes/10485760", // 10MB
            destinationPath: NSTemporaryDirectory() + "test_cancel.bin"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.manager.cancelDownload(taskId: taskId)
        }

        // Verify task was removed
        let expectation = expectation(description: "Task state cleaned up")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let resumeData = UserDefaults.standard.data(forKey: "xdm_resume_\(taskId)")
            XCTAssertNil(resumeData, "Resume data should be removed on cancel")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3)
    }

    // MARK: - State Persistence Tests

    func testActiveTasksStatePersistence() {
        let taskId = "test-state-\(UUID().uuidString)"

        manager.startDownload(
            taskId: taskId,
            urlStr: "https://httpbin.org/bytes/1048576",
            destinationPath: NSTemporaryDirectory() + "test_state.bin"
        )

        let activeIds = UserDefaults.standard.stringArray(forKey: "xdm_active_task_ids")
        XCTAssertNotNil(activeIds)
        XCTAssertTrue(activeIds!.contains(taskId))

        manager.cancelDownload(taskId: taskId)
    }
}
