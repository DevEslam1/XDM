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

    // Callbacks to Flutter
    public var onTorrentsPaused: (() -> Void)?
    public var onTorrentsResumed: (() -> Void)?

    private override init() {
        super.init()
    }

    /// Register the BGProcessingTask for periodic torrent checks.
    public func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskId,
            using: nil
        ) { [weak self] task in
            self?.handleTorrentRefreshTask(task: task as! BGProcessingTask)
        }
    }

    /// Updates the live torrent IDs supplied by the Flutter service.
    public func setActiveTorrentIds(_ ids: [Int]) {
        UserDefaults.standard.set(ids, forKey: activeTorrentsKey)
    }

    /// Called when app enters background. Saves all torrent state.
    public func appDidEnterBackground(activeTorrentIds: [Int]) {
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
    private func handleTorrentRefreshTask(task: BGProcessingTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        // Reschedule next background task
        scheduleTorrentRefresh()
        task.setTaskCompleted(success: true)
    }

    /// Save fast-resume data for a specific torrent.
    public func saveTorrentResumeData(torrentId: Int, data: Data) {
        UserDefaults.standard.set(
            data,
            forKey: "\(resumeDataKeyPrefix)\(torrentId)"
        )
    }

    /// Load fast-resume data for a specific torrent.
    public func loadTorrentResumeData(torrentId: Int) -> Data? {
        return UserDefaults.standard.data(
            forKey: "\(resumeDataKeyPrefix)\(torrentId)"
        )
    }

    /// Clear resume data for a torrent.
    public func clearTorrentResumeData(torrentId: Int) {
        UserDefaults.standard.removeObject(
            forKey: "\(resumeDataKeyPrefix)\(torrentId)"
        )
    }

    /// Get all active torrent IDs.
    public func getActiveTorrentIds() -> [Int] {
        return UserDefaults.standard.array(forKey: activeTorrentsKey) as? [Int] ?? []
    }
}
