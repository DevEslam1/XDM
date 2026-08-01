import XCTest
import Flutter
@testable import Runner

final class IosBackgroundDownloadHandlerTests: XCTestCase {

    func testMethodChannelRegistration() {
        let handler = IosBackgroundDownloadHandler()
        XCTAssertNotNil(handler)
    }

    func testHandleStartNativeDownload() {
        let handler = IosBackgroundDownloadHandler()
        let expectation = expectation(description: "Result returned")

        let call = FlutterMethodCall(
            methodName: "startNativeDownload",
            arguments: [
                "taskId": "test-123",
                "url": "https://httpbin.org/bytes/1024",
                "destinationPath": NSTemporaryDirectory() + "test.bin"
            ]
        )

        handler.handle(call) { result in
            XCTAssertTrue(result as? Bool ?? false)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testHandleCancelNativeDownload() {
        let handler = IosBackgroundDownloadHandler()
        let expectation = expectation(description: "Result returned")

        let call = FlutterMethodCall(
            methodName: "cancelNativeDownload",
            arguments: ["taskId": "nonexistent-task"]
        )

        handler.handle(call) { result in
            XCTAssertTrue(result as? Bool ?? false)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testHandleUnknownMethod() {
        let handler = IosBackgroundDownloadHandler()
        let expectation = expectation(description: "Result returned")

        let call = FlutterMethodCall(
            methodName: "unknownMethod",
            arguments: [:]
        )

        handler.handle(call) { result in
            XCTAssertTrue(result is FlutterMethodNotImplemented)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
    }
}
