import Foundation
import Flutter
import UIKit
import BackgroundTasks

@available(iOS 13.0, *)
@objc public class IosBackgroundDownloadHandler: NSObject, FlutterPlugin {
    public static let downloadTaskIdentifier = "com.dmx.app.download"
    private var channel: FlutterMethodChannel?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.dmx.app/background_download",
            binaryMessenger: registrar.messenger()
        )
        let instance = IosBackgroundDownloadHandler()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
        
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: downloadTaskIdentifier,
            using: nil
        ) { task in
            instance.handleAppRefreshTask(task: task as! BGAppRefreshTask)
        }
    }
    
    public func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
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
