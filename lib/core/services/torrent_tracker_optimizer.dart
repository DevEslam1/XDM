import 'torrent_models.dart';
import 'tracker_manager.dart';

/// Phase 3: Peer Discovery & Tracker Optimization
class TorrentTrackerOptimizer {
  /// Scores and filters working trackers with active seeds and peers.
  static List<TorrentTrackerInfo> getRankedHealthyTrackers(
    List<TorrentTrackerInfo> trackers,
  ) {
    final healthy = trackers
        .where((t) =>
            t.status == TrackerStatus.working && (t.seeds > 0 || t.peers > 0))
        .toList();

    healthy.sort((a, b) {
      final scoreB = (b.seeds * 2) + b.peers;
      final scoreA = (a.seeds * 2) + a.peers;
      return scoreB.compareTo(scoreA);
    });

    return healthy;
  }

  /// Calculates relevance and quality score for a peer connection.
  static double calculatePeerRelevance({
    required double downloadSpeedBytesPerSec,
    required bool isSeed,
    required bool isEncrypted,
    required int failedHashChecks,
  }) {
    var score = 1.0;

    // Penalize peers with failed hash checks
    if (failedHashChecks > 0) {
      score *= 0.5;
    }

    // Prefer encrypted connections
    if (isEncrypted) {
      score *= 1.2;
    }

    // Prefer seeds for maximum download throughput
    if (isSeed) {
      score *= 1.5;
    }

    // Prefer high speed peers (> 100 KB/s)
    if (downloadSpeedBytesPerSec > 100 * 1024) {
      score *= 1.3;
    } else if (downloadSpeedBytesPerSec < 10 * 1024 &&
        downloadSpeedBytesPerSec > 0) {
      // Penalize very slow peers
      score *= 0.7;
    }

    return score.clamp(0.1, 2.5);
  }

  /// Ensures adequate tracker coverage using default tracker pool.
  static void autoAddTrackersIfSparse(
    TrackerManager trackerManager,
    int torrentId,
  ) {
    trackerManager.autoAddDefaultsIfSparse(torrentId);
  }
}
