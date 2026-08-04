import Foundation
import UserNotifications
import BackgroundTasks

/// Manager handling native iOS out-of-process background downloads using URLSession.
@available(iOS 13.0, *)
public class XDMBackgroundDownloadManager: NSObject, URLSessionDownloadDelegate {
    public static let shared = XDMBackgroundDownloadManager()

    private static let appGroupId = "group.com.dmx.app"
    private static let backgroundTaskId = "com.dmx.app.download"

    private var sharedDefaults: UserDefaults? {
        return UserDefaults(suiteName: Self.appGroupId)
    }

    // A1: Dedicated serial queue so delegate callbacks never fire on the main thread.
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "com.dmx.app.download.delegate"
        return q
    }()

    private var session: URLSession!
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var taskMetadata: [String: [String: String]] = [:]
    // A1: O(1) reverse map from URLSessionTask.taskIdentifier → taskId.
    private var taskIdMap: [Int: String] = [:]

    public var onProgressUpdate: ((String, Int64, Int64) -> Void)?
    public var onTaskComplete: ((String, String) -> Void)?
    public var onTaskFailed: ((String, String) -> Void)?

    public var backgroundCompletionHandler: (() -> Void)?

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.dmx.app.background")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // A1: Pass the dedicated serial delegate queue instead of OperationQueue.main.
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        // Restore any in-flight task metadata persisted from a previous run so
        // delegate callbacks fired by a relaunched background session can map
        // their download tasks back to task IDs.
        loadActiveTasksState()
    }

    /// Starts a background download for [urlStr] identified by [taskId].
    public func startDownload(taskId: String, urlStr: String, destinationPath: String) {
        guard let url = URL(string: urlStr) else {
            DispatchQueue.main.async { [weak self] in
                self?.onTaskFailed?(taskId, "Invalid URL string: \(urlStr)")
            }
            return
        }

        let task = session.downloadTask(with: url)
        activeTasks[taskId] = task
        // A1: Keep reverse map in sync.
        taskIdMap[task.taskIdentifier] = taskId
        taskMetadata[taskId] = [
            "url": urlStr,
            "destinationPath": destinationPath
        ]

        // Save state to App Group shared defaults for recovery by the widget
        // extension and for relaunch recovery via BGProcessingTask.
        saveActiveTasksState()

        task.resume()
    }

    /// Pauses an active download.
    public func pauseDownload(taskId: String) {
        guard let task = activeTasks[taskId] else { return }
        task.cancel { [weak self] resumeData in
            if let resumeData = resumeData {
                self?.sharedDefaults?.set(resumeData, forKey: "xdm_resume_\(taskId)")
            }
            // A1: Clean up reverse map on pause (task is being cancelled for resume data).
            self?.taskIdMap.removeValue(forKey: task.taskIdentifier)
            self?.activeTasks.removeValue(forKey: taskId)
            self?.saveActiveTasksState()
        }
    }

    /// Resumes a paused download if resume data exists.
    public func resumeDownload(taskId: String, urlStr: String, destinationPath: String) {
        if let resumeData = sharedDefaults?.data(forKey: "xdm_resume_\(taskId)") {
            let task = session.downloadTask(withResumeData: resumeData)
            activeTasks[taskId] = task
            // A1: Keep reverse map in sync.
            taskIdMap[task.taskIdentifier] = taskId
            taskMetadata[taskId] = [
                "url": urlStr,
                "destinationPath": destinationPath
            ]
            sharedDefaults?.removeObject(forKey: "xdm_resume_\(taskId)")
            saveActiveTasksState()
            task.resume()
        } else {
            startDownload(taskId: taskId, urlStr: urlStr, destinationPath: destinationPath)
        }
    }

    /// Cancels a download.
    public func cancelDownload(taskId: String) {
        guard let task = activeTasks[taskId] else { return }
        task.cancel()
        // A1: Clean up reverse map on cancel.
        taskIdMap.removeValue(forKey: task.taskIdentifier)
        activeTasks.removeValue(forKey: taskId)
        taskMetadata.removeValue(forKey: taskId)
        sharedDefaults?.removeObject(forKey: "xdm_resume_\(taskId)")
        saveActiveTasksState()
    }

    /// Whether any downloads are active or persisted but not yet complete.
    public func hasActiveDownloads() -> Bool {
        return !activeTasks.isEmpty || !taskMetadata.isEmpty
    }

    /// Count of currently active task downloads (for logging).
    public var activeTaskCount: Int {
        return activeTasks.count
    }

    /// Re-creates download tasks for any still-active metadata. Used by the
    /// BGProcessingTask handler to keep downloads moving after a background
    /// relaunch.
    public func resumeActiveDownloads(completion: @escaping () -> Void) {
        loadActiveTasksState()
        let ids = Array(taskMetadata.keys)
        for taskId in ids {
            guard activeTasks[taskId] == nil,
                  let meta = taskMetadata[taskId],
                  let urlStr = meta["url"],
                  let destPath = meta["destinationPath"],
                  !urlStr.isEmpty, !destPath.isEmpty else { continue }
            startDownload(taskId: taskId, urlStr: urlStr, destinationPath: destPath)
        }
        completion()
    }

    /// FIX-C1b: Like resumeActiveDownloads but verifies resume data integrity
    /// before attempting to resume. Tasks with no persisted resume data are
    /// skipped instead of starting a fresh download (which would re-download
    /// from byte 0, wasting bandwidth and potentially corrupting partial files).
    public func resumeActiveDownloadsWithVerification(completion: @escaping () -> Void) {
        loadActiveTasksState()
        let ids = Array(taskMetadata.keys)
        for taskId in ids {
            guard activeTasks[taskId] == nil,
                  let meta = taskMetadata[taskId],
                  let urlStr = meta["url"],
                  let destPath = meta["destinationPath"],
                  !urlStr.isEmpty, !destPath.isEmpty else { continue }

            // FIX-C1b: Check if resume data is available. If yes, resume.
            // If no resume data, skip this task — a fresh start should only
            // be initiated from within the app, not from a background wakeup.
            if let resumeData = sharedDefaults?.data(forKey: "xdm_resume_\(taskId)"),
               !resumeData.isEmpty {
                print("XDM BG: Resuming task \(taskId) with \(resumeData.count) bytes of resume data")
                let task = session.downloadTask(withResumeData: resumeData)
                activeTasks[taskId] = task
                taskIdMap[task.taskIdentifier] = taskId
                sharedDefaults?.removeObject(forKey: "xdm_resume_\(taskId)")
                saveActiveTasksState()
                task.resume()
            } else {
                print("XDM BG: Skipping task \(taskId) — no resume data available (not starting fresh from background)")
            }
        }
        completion()
    }

    /// Persists active download state to the App Group shared container so the
    /// widget extension and the background task handler can read it.
    func saveActiveTasksState() {
        guard let defaults = sharedDefaults else {
            print("XDM BG: WARNING - App Group UserDefaults not available")
            return
        }
        defaults.set(Array(taskMetadata.keys), forKey: "xdm_active_task_ids")
        defaults.set(taskMetadata, forKey: "xdm_active_tasks_state")
    }

    /// Loads persisted download state from the App Group shared container.
    /// Nil-safe: silently returns when the App Group is unavailable.
    private func loadActiveTasksState() {
        guard let defaults = sharedDefaults else {
            print("XDM BG: WARNING - App Group UserDefaults not available")
            return
        }
        let ids = defaults.array(forKey: "xdm_active_task_ids") as? [String] ?? []
        let meta = defaults.dictionary(forKey: "xdm_active_tasks_state") as? [String: [String: String]] ?? [:]
        for id in ids where taskMetadata[id] == nil {
            if let entry = meta[id] { taskMetadata[id] = entry }
        }
    }

    /// Cancels any scheduled download BGProcessingTask (called when the last
    /// download finishes so iOS does not waste a background wake).
    private func cancelScheduledBackgroundTask() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskId)
    }

    // MARK: - URLSessionDownloadDelegate
    // A1: All callbacks fire on delegateQueue (not main). Heavy bookkeeping
    //     (map lookups, state writes) runs here. Only Flutter channel calls
    //     hop to DispatchQueue.main explicitly.

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // A1: O(1) lookup via reverse map — runs on delegateQueue.
        guard let taskId = taskIdMap[downloadTask.taskIdentifier] else { return }
        let callback = onProgressUpdate
        DispatchQueue.main.async {
            callback?(taskId, totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // A1: Runs on delegateQueue. File move is heavy I/O — stays here.
        guard let taskId = taskIdMap[downloadTask.taskIdentifier],
              let meta = taskMetadata[taskId],
              let destPath = meta["destinationPath"] else { return }

        let fileManager = FileManager.default
        let destURL = URL(fileURLWithPath: destPath)
        let metaCopy = meta

        do {
            if fileManager.fileExists(atPath: destPath) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.moveItem(at: location, to: destURL)
            // A1: Remove from all tracking maps after file is in place.
            taskIdMap.removeValue(forKey: downloadTask.taskIdentifier)
            activeTasks.removeValue(forKey: taskId)
            taskMetadata.removeValue(forKey: taskId)
            saveActiveTasksState()
            if activeTasks.isEmpty {
                cancelScheduledBackgroundTask()
            }

            // A1: Hop Flutter channel callbacks to main.
            let completeCallback = onTaskComplete
            DispatchQueue.main.async {
                completeCallback?(taskId, destPath)
            }

            postCompletionNotification(
                taskId: taskId,
                destPath: destPath,
                url: URL(string: metaCopy["url"] ?? "")
            )
        } catch {
            let failCallback = onTaskFailed
            let errDesc = error.localizedDescription
            DispatchQueue.main.async {
                failCallback?(taskId, "Failed to move file to destination: \(errDesc)")
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A1: Runs on delegateQueue. Only hop to main for Flutter callback.
        if let downloadTask = task as? URLSessionDownloadTask,
           let taskId = taskIdMap[downloadTask.taskIdentifier],
           let error = error {
            // A1: Remove from all tracking maps on error.
            taskIdMap.removeValue(forKey: downloadTask.taskIdentifier)
            activeTasks.removeValue(forKey: taskId)
            taskMetadata.removeValue(forKey: taskId)
            saveActiveTasksState()
            let failCallback = onTaskFailed
            let errDesc = error.localizedDescription
            DispatchQueue.main.async {
                failCallback?(taskId, errDesc)
            }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            if let completionHandler = self?.backgroundCompletionHandler {
                self?.backgroundCompletionHandler = nil
                completionHandler()
            }
        }
    }

    /// Posts a local "Download Complete" notification. The identifier carries
    /// the taskId and the userInfo carries task metadata for the
    /// pause/resume/cancel notification actions.
    private func postCompletionNotification(taskId: String, destPath: String, url: URL?) {
        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = URL(fileURLWithPath: destPath).lastPathComponent
        content.sound = .default
        content.badge = 0
        content.userInfo = [
            "taskId": taskId,
            "destinationPath": destPath,
            "url": url?.absoluteString ?? ""
        ]

        let request = UNNotificationRequest(
            identifier: "xdm_bg_download_\(taskId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("XDM BG: Failed to post notification: \(error)")
            }
        }
    }

    // A1: findTaskId(for:) retained for any external callers, but internally
    //     replaced by the O(1) taskIdMap lookup in all delegate callbacks.
    private func findTaskId(for task: URLSessionDownloadTask) -> String? {
        return taskIdMap[task.taskIdentifier]
    }
}