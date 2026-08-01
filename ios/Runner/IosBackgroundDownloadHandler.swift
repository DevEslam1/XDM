import Foundation
import Flutter
import UIKit
import BackgroundTasks

@available(iOS 13.0, *)
@objc public class IosBackgroundDownloadHandler: NSObject, FlutterPlugin, FlutterStreamHandler {
    public static let downloadTaskIdentifier = "com.dmx.app.download"
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = IosBackgroundDownloadHandler()
        
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
        
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: downloadTaskIdentifier,
            using: nil
        ) { task in
            instance.handleAppRefreshTask(task: task as! BGAppRefreshTask)
        }
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            if call.method == "scheduleDownload" {
                scheduleBackgroundFetch()
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
            result(true)
        case "pauseNativeDownload":
            XDMBackgroundDownloadManager.shared.pauseDownload(taskId: taskId)
            result(true)
        case "resumeNativeDownload":
            XDMBackgroundDownloadManager.shared.resumeDownload(taskId: taskId, urlStr: url, destinationPath: destinationPath)
            result(true)
        case "cancelNativeDownload":
            XDMBackgroundDownloadManager.shared.cancelDownload(taskId: taskId)
            result(true)
        case "scheduleDownload":
            scheduleBackgroundFetch()
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
    
    private func scheduleBackgroundFetch() {
        let request = BGAppRefreshTaskRequest(identifier: Self.downloadTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("XDM: Could not schedule iOS background refresh task: \(error)")
        }
    }
    
    private func handleAppRefreshTask(task: BGAppRefreshTask) {
        scheduleBackgroundFetch()
        
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        
        task.expirationHandler = {
            queue.cancelAllOperations()
        }
        
        task.setTaskCompleted(success: true)
    }
}
