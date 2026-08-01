import Foundation
import UserNotifications

/// Manager handling native iOS out-of-process background downloads using URLSession.
@available(iOS 13.0, *)
public class XDMBackgroundDownloadManager: NSObject, URLSessionDownloadDelegate {
    public static let shared = XDMBackgroundDownloadManager()
    
    private var session: URLSession!
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var taskMetadata: [String: [String: String]] = [:]
    
    public var onProgressUpdate: ((String, Int64, Int64) -> Void)?
    public var onTaskComplete: ((String, String) -> Void)?
    public var onTaskFailed: ((String, String) -> Void)?
    
    public var backgroundCompletionHandler: (() -> Void)?

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.dmx.app.background")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
    }

    /// Starts a background download for [urlStr] identified by [taskId].
    public func startDownload(taskId: String, urlStr: String, destinationPath: String) {
        guard let url = URL(string: urlStr) else {
            onTaskFailed?(taskId, "Invalid URL string: \(urlStr)")
            return
        }

        let task = session.downloadTask(with: url)
        activeTasks[taskId] = task
        taskMetadata[taskId] = [
            "url": urlStr,
            "destinationPath": destinationPath
        ]
        
        // Save state to UserDefaults for recovery
        saveActiveTasksState()
        
        task.resume()
    }

    /// Pauses an active background download.
    public func pauseDownload(taskId: String) {
        guard let task = activeTasks[taskId] else { return }
        task.cancel { [weak self] resumeData in
            if let resumeData = resumeData {
                UserDefaults.standard.set(resumeData, forKey: "xdm_resume_\(taskId)")
            }
            self?.activeTasks.removeValue(forKey: taskId)
            self?.saveActiveTasksState()
        }
    }

    /// Resumes a paused background download if resume data exists.
    public func resumeDownload(taskId: String, urlStr: String, destinationPath: String) {
        if let resumeData = UserDefaults.standard.data(forKey: "xdm_resume_\(taskId)") {
            let task = session.downloadTask(withResumeData: resumeData)
            activeTasks[taskId] = task
            taskMetadata[taskId] = [
                "url": urlStr,
                "destinationPath": destinationPath
            ]
            UserDefaults.standard.removeObject(forKey: "xdm_resume_\(taskId)")
            saveActiveTasksState()
            task.resume()
        } else {
            startDownload(taskId: taskId, urlStr: urlStr, destinationPath: destinationPath)
        }
    }

    /// Cancels a background download.
    public func cancelDownload(taskId: String) {
        guard let task = activeTasks[taskId] else { return }
        task.cancel()
        activeTasks.removeValue(forKey: taskId)
        taskMetadata.removeValue(forKey: taskId)
        UserDefaults.standard.removeObject(forKey: "xdm_resume_\(taskId)")
        saveActiveTasksState()
    }

    private func saveActiveTasksState() {
        let metaKeys = Array(taskMetadata.keys)
        UserDefaults.standard.set(metaKeys, forKey: "xdm_active_task_ids")
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let taskId = findTaskId(for: downloadTask) {
            onProgressUpdate?(taskId, totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let taskId = findTaskId(for: downloadTask),
              let meta = taskMetadata[taskId],
              let destPath = meta["destinationPath"] else { return }

        let fileManager = FileManager.default
        let destURL = URL(fileURLWithPath: destPath)
        
        do {
            if fileManager.fileExists(atPath: destPath) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.moveItem(at: location, to: destURL)
            activeTasks.removeValue(forKey: taskId)
            taskMetadata.removeValue(forKey: taskId)
            saveActiveTasksState()
            onTaskComplete?(taskId, destPath)
        } catch {
            onTaskFailed?(taskId, "Failed to move file to destination: \(error.localizedDescription)")
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let downloadTask = task as? URLSessionDownloadTask,
           let taskId = findTaskId(for: downloadTask),
           let error = error {
            activeTasks.removeValue(forKey: taskId)
            taskMetadata.removeValue(forKey: taskId)
            saveActiveTasksState()
            onTaskFailed?(taskId, error.localizedDescription)
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

    private func findTaskId(for task: URLSessionDownloadTask) -> String? {
        for (id, activeTask) in activeTasks where activeTask == task {
            return id
        }
        return nil
    }
}
