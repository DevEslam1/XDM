import Foundation
import UIKit
import BackgroundTasks
import Flutter

/// Controller handling native iOS out-of-process background downloads
/// via BGProcessingTaskRequest and URLSessionConfiguration.background.
@available(iOS 13.0, *)
@objc public class BackgroundDownloadController: NSObject, URLSessionDownloadDelegate, FlutterPlugin, FlutterStreamHandler {
    public static let shared = BackgroundDownloadController()
    public static let downloadTaskIdentifier = "com.dmx.app.download"
    public static let sessionIdentifier = "com.dmx.app.background"
    
    private var session: URLSession!
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var taskMetadata: [String: [String: String]] = [:]
    private var taskIdMap: [Int: String] = [:]
    
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?
    
    public var backgroundCompletionHandler: (() -> Void)?
    
    private let serialQueue = DispatchQueue(label: "com.dmx.app.background_download_queue")
    
    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.shouldSetCookies = true
        
        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 1
        opQueue.name = "com.dmx.app.download.delegate_queue"
        
        session = URLSession(configuration: config, delegate: self, delegateQueue: opQueue)
        loadPersistedState()
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = BackgroundDownloadController.shared
        
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
    }
    
    // MARK: - Flutter Method Handling
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isBackgroundSupported":
            result(true)
            
        case "scheduleDownload", "scheduleBackground":
            scheduleBackgroundProcessing()
            result(true)
            
        case "startNativeDownload", "start":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Arguments missing", details: nil))
                return
            }
            let taskId = (args["taskId"] as? String) ?? (args["id"] as? String) ?? UUID().uuidString
            let urlStr = args["url"] as? String ?? ""
            let destPath = (args["destinationPath"] as? String) ?? (args["savePath"] as? String) ?? ""
            startDownload(taskId: taskId, urlString: urlStr, destinationPath: destPath)
            scheduleBackgroundProcessing()
            result(true)
            
        case "pauseNativeDownload", "pause":
            guard let args = call.arguments as? [String: Any],
                  let taskId = (args["taskId"] as? String) ?? (args["id"] as? String) else {
                result(false)
                return
            }
            pauseDownload(taskId: taskId)
            result(true)
            
        case "resumeNativeDownload", "resume":
            guard let args = call.arguments as? [String: Any],
                  let taskId = (args["taskId"] as? String) ?? (args["id"] as? String),
                  let urlStr = args["url"] as? String,
                  let destPath = (args["destinationPath"] as? String) ?? (args["savePath"] as? String) else {
                result(false)
                return
            }
            resumeDownload(taskId: taskId, urlString: urlStr, destinationPath: destPath)
            scheduleBackgroundProcessing()
            result(true)
            
        case "cancelNativeDownload", "cancel":
            guard let args = call.arguments as? [String: Any],
                  let taskId = (args["taskId"] as? String) ?? (args["id"] as? String) else {
                result(false)
                return
            }
            cancelDownload(taskId: taskId)
            result(true)
            
        case "getActiveTasksCount":
            result(activeTasks.count)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Download Operations
    
    public func startDownload(taskId: String, urlString: String, destinationPath: String) {
        guard let url = URL(string: urlString) else {
            sendEvent([
                "event": "failed",
                "taskId": taskId,
                "error": "Malformed URL: \(urlString)"
            ])
            return
        }
        
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            let task = self.session.downloadTask(with: url)
            self.activeTasks[taskId] = task
            self.taskIdMap[task.taskIdentifier] = taskId
            self.taskMetadata[taskId] = [
                "url": urlString,
                "destinationPath": destinationPath
            ]
            self.persistState()
            task.resume()
        }
    }
    
    public func pauseDownload(taskId: String) {
        serialQueue.async { [weak self] in
            guard let self = self, let task = self.activeTasks[taskId] else { return }
            task.cancel(byProducingResumeData: { [weak self] resumeData in
                guard let self = self, let data = resumeData else { return }
                self.saveResumeData(taskId: taskId, data: data)
            })
            self.activeTasks.removeValue(forKey: taskId)
            self.persistState()
        }
    }
    
    public func resumeDownload(taskId: String, urlString: String, destinationPath: String) {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            if let resumeData = self.loadResumeData(taskId: taskId) {
                let task = self.session.downloadTask(withResumeData: resumeData)
                self.activeTasks[taskId] = task
                self.taskIdMap[task.taskIdentifier] = taskId
                self.taskMetadata[taskId] = [
                    "url": urlString,
                    "destinationPath": destinationPath
                ]
                self.persistState()
                task.resume()
            } else {
                self.startDownload(taskId: taskId, urlString: urlString, destinationPath: destinationPath)
            }
        }
    }
    
    public func cancelDownload(taskId: String) {
        serialQueue.async { [weak self] in
            guard let self = self, let task = self.activeTasks[taskId] else { return }
            task.cancel()
            self.activeTasks.removeValue(forKey: taskId)
            self.taskMetadata.removeValue(forKey: taskId)
            self.removeResumeData(taskId: taskId)
            self.persistState()
        }
    }
    
    // MARK: - BGProcessingTaskRequest
    
    public func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.downloadTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BackgroundDownloadController] Scheduled BGProcessingTaskRequest")
        } catch {
            print("[BackgroundDownloadController] Failed to submit BGProcessingTaskRequest: \(error)")
        }
    }
    
    public func handleBackgroundProcessingTask(task: BGProcessingTask) {
        task.expirationHandler = { [weak self] in
            self?.serialQueue.async {
                self?.persistState()
                task.setTaskCompleted(success: false)
            }
        }
        
        serialQueue.async { [weak self] in
            guard let self = self else {
                task.setTaskCompleted(success: false)
                return
            }
            // Resume any interrupted downloads with resume data
            for (taskId, meta) in self.taskMetadata where self.activeTasks[taskId] == nil {
                if let urlStr = meta["url"], let dest = meta["destinationPath"] {
                    self.resumeDownload(taskId: taskId, urlString: urlStr, destinationPath: dest)
                }
            }
            self.scheduleBackgroundProcessing()
            task.setTaskCompleted(success: true)
        }
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let taskId = taskIdMap[downloadTask.taskIdentifier] else { return }
        sendEvent([
            "event": "progress",
            "taskId": taskId,
            "downloadedBytes": totalBytesWritten,
            "totalBytes": totalBytesExpectedToWrite
        ])
    }
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let taskId = taskIdMap[downloadTask.taskIdentifier],
              let destPath = taskMetadata[taskId]?["destinationPath"] else { return }
        
        let destURL = URL(fileURLWithPath: destPath)
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destPath) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.moveItem(at: location, to: destURL)
            sendEvent([
                "event": "completed",
                "taskId": taskId,
                "path": destPath
            ])
        } catch {
            sendEvent([
                "event": "failed",
                "taskId": taskId,
                "error": error.localizedDescription
            ])
        }
        
        activeTasks.removeValue(forKey: taskId)
        taskMetadata.removeValue(forKey: taskId)
        removeResumeData(taskId: taskId)
        persistState()
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let taskId = taskIdMap[task.taskIdentifier] else { return }
        if let error = error {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                // Cancelled manually or saved resume data
                return
            }
            sendEvent([
                "event": "failed",
                "taskId": taskId,
                "error": error.localizedDescription
            ])
        }
    }
    
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
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
    
    private func sendEvent(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(event)
        }
    }
    
    // MARK: - State Persistence
    
    private func persistState() {
        let defaults = UserDefaults(suiteName: "group.com.dmx.app")
        defaults?.set(taskMetadata, forKey: "dmx_bg_tasks")
    }
    
    private func loadPersistedState() {
        let defaults = UserDefaults(suiteName: "group.com.dmx.app")
        if let meta = defaults?.dictionary(forKey: "dmx_bg_tasks") as? [String: [String: String]] {
            taskMetadata = meta
        }
    }
    
    private func saveResumeData(taskId: String, data: Data) {
        let path = getResumeDataPath(taskId: taskId)
        try? data.write(to: URL(fileURLWithPath: path))
    }
    
    private func loadResumeData(taskId: String) -> Data? {
        let path = getResumeDataPath(taskId: taskId)
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }
    
    private func removeResumeData(taskId: String) {
        let path = getResumeDataPath(taskId: taskId)
        try? FileManager.default.removeItem(atPath: path)
    }
    
    private func getResumeDataPath(taskId: String) -> String {
        let tempDir = NSTemporaryDirectory()
        return (tempDir as NSString).appendingPathComponent("resume_\(taskId).dat")
    }
}
