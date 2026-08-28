import '../domain/torrent_models.dart';
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

/// Health metrics for a single BitTorrent tracker.
class TrackerHealth {
  int successes = 0;
  int failures = 0;
  double avgSeeds = 0.0;
  double avgLatencyMs = 0.0;
  DateTime lastAnnounce = DateTime.fromMillisecondsSinceEpoch(0);

  double get score {
    if (failures >= 5) return 0.0; // Tracker unresponsive
    final reliability = successes / (successes + failures + 1);
    final seedScore = (avgSeeds / 100.0).clamp(0.0, 1.0);
    final latencyScore = 1.0 / (1.0 + avgLatencyMs / 500.0);
    return (reliability * 0.5) + (seedScore * 0.3) + (latencyScore * 0.2);
  }
}

/// Smart tracker tier manager that ranks trackers by health and manages announces.
class SmartTrackerManager {
  final Map<String, TrackerHealth> _trackerHealth = {};

  TrackerHealth healthFor(String url) =>
      _trackerHealth.putIfAbsent(url, () => TrackerHealth());

  void recordTrackerResult(
    String url, {
    required bool success,
    int seeds = 0,
    double latencyMs = 0,
  }) {
    final health = healthFor(url);
    health.lastAnnounce = DateTime.now();
    if (success) {
      health.successes++;
      health.failures = 0;
      health.avgSeeds = 0.7 * seeds + 0.3 * health.avgSeeds;
      health.avgLatencyMs = 0.7 * latencyMs + 0.3 * health.avgLatencyMs;
    } else {
      health.failures++;
    }
  }

  /// Calculates announce delay based on failure backoff.
  Duration computeBackoffDelay(String url) {
    final health = _trackerHealth[url];
    if (health == null || health.failures <= 0) return Duration.zero;
    final exponent = health.failures.clamp(1, 6);
    return Duration(seconds: 2 * (1 << (exponent - 1)));
  }

  /// Returns trackers sorted by composite health score.
  List<TorrentTrackerInfo> rankTrackers(List<TorrentTrackerInfo> trackers) {
    final sorted = List<TorrentTrackerInfo>.from(trackers);
    sorted.sort((a, b) {
      final scoreA = healthFor(a.url).score;
      final scoreB = healthFor(b.url).score;
      return scoreB.compareTo(scoreA);
    });
    return sorted;
  }
}
