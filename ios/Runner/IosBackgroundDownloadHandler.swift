import Foundation
import Flutter
import UIKit
import BackgroundTasks

@available(iOS 13.0, *)
@objc public class IosBackgroundDownloadHandler: NSObject, FlutterPlugin, FlutterStreamHandler {
    public static let downloadTaskIdentifier = "com.dmx.app.download"
    public static let shared = IosBackgroundDownloadHandler()
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = IosBackgroundDownloadHandler.shared
        
        let methodChan = FlutterMethodChannel(
            name: "com.dmx.app/background_download",
            binaryMessenger: registrar.messenger()
        )
        instance.methodChannel = methodChan
        registrar.addMethodCallDelegate(instance, channel: methodChan)
        
        let eventChan = FlutterEventChannel(
            name: "com.dmx.app/background_download_events",
            binaryMessenger: registrar.messenger()
        )
        instance.eventChannel = eventChan
        eventChan.setStreamHandler(instance)
        
        // Connect manager callbacks to EventChannel stream
        XDMBackgroundDownloadManager.shared.onProgressUpdate = { taskId, written, total in
            instance.eventSink?([
                "event": "progress",
                "taskId": taskId,
                "downloadedBytes": written,
                "totalBytes": total
            ])
        }
        
        XDMBackgroundDownloadManager.shared.onTaskComplete = { taskId, path in
            instance.eventSink?([
                "event": "completed",
                "taskId": taskId,
                "path": path
            ])
        }
        
        XDMBackgroundDownloadManager.shared.onTaskFailed = { taskId, error in
            instance.eventSink?([
                "event": "failed",
                "taskId": taskId,
                "error": error
            ])
        }
        
        // NOTE: The BGTaskScheduler handler for com.dmx.app.download is
        // registered in AppDelegate.application(_:didFinishLaunchingWithOptions:)
        // BEFORE the Flutter engine is set up. Registering the same identifier
        // here too would crash with a duplicate-registration assertion.
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            if call.method == "scheduleDownload" {
                scheduleBackgroundProcessing()
                result(true)
                return
            } else if call.method == "cancelDownload" {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.downloadTaskIdentifier)
                result(true)
                return
            }
            result(FlutterMethodNotImplemented)
            return
        }
        
        let taskId = args["taskId"] as? String ?? ""
        let url = args["url"] as? String ?? ""
        let destinationPath = args["destinationPath"] as? String ?? ""
        
        switch call.method {
        case "startNativeDownload":
            XDMBackgroundDownloadManager.shared.startDownload(taskId: taskId, urlStr: url, destinationPath: destinationPath)
            scheduleBackgroundProcessing()
            result(true)
        case "pauseNativeDownload":
            XDMBackgroundDownloadManager.shared.pauseDownload(taskId: taskId)
            result(true)
        case "resumeNativeDownload":
            XDMBackgroundDownloadManager.shared.resumeDownload(taskId: taskId, urlStr: url, destinationPath: destinationPath)
            scheduleBackgroundProcessing()
            result(true)
        case "cancelNativeDownload":
            XDMBackgroundDownloadManager.shared.cancelDownload(taskId: taskId)
            result(true)
        case "scheduleDownload":
            scheduleBackgroundProcessing()
            result(true)
        case "cancelDownload":
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.downloadTaskIdentifier)
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - FlutterStreamHandler
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
    
    // MARK: - Background Processing Task
    
    /// Schedules a BGProcessingTask that wakes the app to keep active
    /// downloads moving while it is in the background.
    public func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.downloadTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        // FIX(A-5): Set earliestBeginDate to 15 minutes from now as required by iOS 13+
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("XDM BG: Background processing task scheduled (earliest in 15 min)")

        } catch {
            print("XDM BG: Failed to schedule background task: \(error)")
        }
    }
    
    /// Handles the background processing task for active downloads.
    /// Saves state on expiration, resumes any persisted downloads, and
    /// reschedules the next background window. No silent failures — all
    /// paths are logged and the task is always completed.
    public func handleDownloadTask(task: BGProcessingTask) {
        // FIX-L13: Add detailed logging for debugging background task issues.
        let activeCount = XDMBackgroundDownloadManager.shared.activeTaskCount
        print("XDM BG: Processing task with \(activeCount) active download(s)")
        
        task.expirationHandler = {
            print("XDM BG: Task expired, saving state. Active count: \(XDMBackgroundDownloadManager.shared.activeTaskCount)")
            XDMBackgroundDownloadManager.shared.saveActiveTasksState()
            task.setTaskCompleted(success: false)
        }
        
        // FIX-C1b: Verify resume data exists for each task before resuming.
        // Skip tasks with no resume data to avoid starting fresh downloads
        // when the expectation is to resume from where we left off.
        XDMBackgroundDownloadManager.shared.resumeActiveDownloadsWithVerification {
            print("XDM BG: Resume-with-verification complete")
            task.setTaskCompleted(success: true)
        }
        
        // Reschedule for the next background window
        scheduleBackgroundProcessing()
    }
}