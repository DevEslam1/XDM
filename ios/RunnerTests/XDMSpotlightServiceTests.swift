import XCTest
import CoreSpotlight
@testable import Runner

final class XDMSpotlightServiceTests: XCTestCase {

    var service: XDMSpotlightService!

    override func setUp() {
        super.setUp()
        service = XDMSpotlightService.shared
    }

    func testIndexDownloadedFile() {
        let taskId = "spotlight-test-\(UUID().uuidString)"
        let expectation = expectation(description: "Indexed")

        service.indexDownloadedFile(
            taskId: taskId,
            title: "Test Document.pdf",
            filePath: "/tmp/test.pdf",
            mimeType: "application/pdf"
        )

        // Give Spotlight time to index
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            expectation.fulfill()
        }

        waitForExpectations(timeout: 3)

        // Cleanup
        service.deindexFile(taskId: taskId)
    }

    func testDeindexFile() {
        let taskId = "spotlight-deindex-\(UUID().uuidString)"

        // Index first
        service.indexDownloadedFile(
            taskId: taskId,
            title: "To Remove.pdf",
            filePath: "/tmp/remove.pdf",
            mimeType: "application/pdf"
        )

        // Then deindex
        let expectation = expectation(description: "Deindexed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.service.deindexFile(taskId: taskId)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 3)
    }
}
