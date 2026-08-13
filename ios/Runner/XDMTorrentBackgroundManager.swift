import Foundation
import BackgroundTasks

/// Manages torrent background behavior on iOS.
///
/// Strategy: iOS does NOT allow arbitrary background execution for P2P.
/// libtorrent runs in-process and CANNOT run when suspended.
///
/// Our approach:
/// 1. When app enters background → save fast-resume data for all active torrents
/// 2. Schedule a BGProcessingTask to periodically wake and check torrents
/// 3. When app resumes → reload fast-resume data and resume torrents
///
/// This is graceful pause/resume with minimal data loss.
@available(iOS 13.0, *)
public class XDMTorrentBackgroundManager: NSObject {
    public static let shared = XDMTorrentBackgroundManager()
    public static let processingTaskId = "com.dmx.app.torrent.refresh"

    private let resumeDataKeyPrefix = "xdm_torrent_resume_"
    private let activeTorrentsKey = "xdm_active_torrent_ids"

    // A2: Static flag ensures registerBackgroundTask() is a no-op if the
    //     identifier was already registered in AppDelegate, preventing an
    //     assert-crash from double-registration.
    private static var _registered = false

    // A3: Debounce timestamp so simultaneous AppDelegate + SceneDelegate
    //     background callbacks don't schedule two BGProcessingTasks.
    private var _lastBackgroundAt: Date? = nil
    private static let _backgroundDebounceSeconds: TimeInterval = 2.0

    // Callbacks to Flutter
    public var onTorrentsPaused: (() -> Void)?
    public var onTorrentsResumed: (() -> Void)?

    private override init() {
        super.init()
    }

    /// Register the BGProcessingTask for periodic torrent checks.
    /// A2: Guarded by a static flag — safe to call more than once; only
    ///     the first call performs the actual BGTaskScheduler registration.
    public func registerBackgroundTask() {
        guard !Self._registered else { return }
        Self._registered = true
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskId,
            using: nil
        ) { [weak self] task in
            // A2: Safe cast — guard against iOS delivering an unexpected BGTask subclass.
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleTorrentRefreshTask(task: processingTask)
        }
    }

    /// Updates the live torrent IDs supplied by the Flutter service.
    public func setActiveTorrentIds(_ ids: [Int]) {
        UserDefaults.standard.set(ids, forKey: activeTorrentsKey)
    }

    /// Called when app enters background. Saves all torrent state.
    /// A3: Idempotent within a 2-second window to prevent double-invocation
    ///     from both AppDelegate and SceneDelegate firing simultaneously.
    public func appDidEnterBackground(activeTorrentIds: [Int]) {
        let now = Date()
        if let last = _lastBackgroundAt,
           now.timeIntervalSince(last) < Self._backgroundDebounceSeconds {
            // A3: Duplicate call within debounce window — skip to avoid
            //     double-scheduling the BGProcessingTask.
            print("XDM Torrent BG: Debouncing duplicate background callback")
            return
        }
        _lastBackgroundAt = now

        // Save active torrent IDs
        UserDefaults.standard.set(activeTorrentIds, forKey: activeTorrentsKey)

        // Schedule background processing task
        scheduleTorrentRefresh()

        // Notify Flutter to save fast-resume data
        onTorrentsPaused?()

        print("XDM Torrent BG: Saved \(activeTorrentIds.count) torrent states")
    }

    /// Called when app returns to foreground. Resumes all torrents.
    public func appWillEnterForeground() {
        // Reset the debounce timestamp so the next background transition
        // is processed normally.
        _lastBackgroundAt = nil

        // Cancel pending background task
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: Self.processingTaskId
        )

        // Notify Flutter to resume torrents from fast-resume data
        onTorrentsResumed?()

        print("XDM Torrent BG: Resuming torrents from fast-resume data")
    }

    /// Schedule a BGProcessingTask to check torrents periodically.
    private func scheduleTorrentRefresh() {
        let request = BGProcessingTaskRequest(
            identifier: Self.processingTaskId
        )
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("XDM Torrent BG: Scheduled refresh task")
        } catch {
            print("XDM Torrent BG: Failed to schedule: \(error)")
        }
    }

    /// Handle the background processing task.
    public func handleTorrentRefreshTask(task: BGProcessingTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        // Reschedule next background task
        scheduleTorrentRefresh()
        task.setTaskCompleted(success: true)
    }

    private var resumeDir: URL {
        let fileManager = FileManager.default
        let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.dmx.app") 
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = container.appendingPathComponent("torrent_resume", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }

    /// Save fast-resume data for a specific torrent using atomic file write.
    public func saveTorrentResumeData(torrentId: Int, data: Data) {
        guard data.count <= 1024 * 1024 else { return }
        let target = resumeDir.appendingPathComponent("\(torrentId).resume")
        let tmp = resumeDir.appendingPathComponent("\(torrentId).resume.tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: tmp, to: target)
        } catch {
            print("XDM Torrent BG: Save resume data failed for \(torrentId): \(error)")
        }
    }

    /// Load fast-resume data for a specific torrent from file storage.
    public func loadTorrentResumeData(torrentId: Int) -> Data? {
        let file = resumeDir.appendingPathComponent("\(torrentId).resume")
        guard let data = try? Data(contentsOf: file), data.count <= 1024 * 1024 else { return nil }
        return data
    }

    /// Clear resume data for a torrent.
    public func clearTorrentResumeData(torrentId: Int) {
        let file = resumeDir.appendingPathComponent("\(torrentId).resume")
        try? FileManager.default.removeItem(at: file)
    }

    /// Get all active torrent IDs.
    public func getActiveTorrentIds() -> [Int] {
        return UserDefaults.standard.array(forKey: activeTorrentsKey) as? [Int] ?? []
    }
}
