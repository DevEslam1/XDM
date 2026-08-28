import 'dart:math';

/// Tracks throughput statistics and optimal concurrency per remote host.
class HostConcurrencyProfile {
  HostConcurrencyProfile(this.host, [int initialThreads = 4])
      : optimalThreads = initialThreads.clamp(1, 16),
        maxObservedThreads = initialThreads.clamp(1, 16),
        avgSpeedPerThread = 0.0,
        lastUpdated = DateTime.now();

  final String host;
  int optimalThreads;
  int maxObservedThreads;
  double avgSpeedPerThread;
  DateTime lastUpdated;
  DateTime _lastScaleChange = DateTime.fromMillisecondsSinceEpoch(0);

  /// Records speed in bytes per second achieved across [threads].
  void recordSpeed(double bytesPerSec, int threads) {
    if (threads <= 0 || bytesPerSec <= 0) return;
    final perThread = bytesPerSec / threads;
    maxObservedThreads = max(maxObservedThreads, threads);

    final prevAvg = avgSpeedPerThread;
    if (avgSpeedPerThread == 0.0) {
      avgSpeedPerThread = perThread;
    } else {
      // Exponential moving average: favor recent measurements (70% weight)
      avgSpeedPerThread = 0.7 * perThread + 0.3 * avgSpeedPerThread;
    }

    // FIX 10/10: Hysteresis + cooldown to prevent flap under jitter.
    // Previously 0.85 down / 0.95 up with EMA 0.7 caused oscillation 1..16 every sample.
    // Now 0.80 down / 0.97 up with 10s cooldown and stable EMA branch.
    final now = DateTime.now();
    final canScale = now.difference(_lastScaleChange).inSeconds >= 10;
    if (canScale) {
      if (prevAvg > 0.0 &&
          threads >= optimalThreads - 1 &&
          perThread < prevAvg * 0.80) {
        optimalThreads = max(1, optimalThreads - 1);
        _lastScaleChange = now;
      } else if (prevAvg > 0.0 &&
          threads >= optimalThreads &&
          perThread >= avgSpeedPerThread * 0.97) {
        optimalThreads = min(16, optimalThreads + 1);
        _lastScaleChange = now;
      }
    }

    lastUpdated = DateTime.now();
  }

  /// Manually reset or override optimal threads for this host
  void reset([int initialThreads = 4]) {
    optimalThreads = initialThreads.clamp(1, 16);
    avgSpeedPerThread = 0.0;
    lastUpdated = DateTime.now();
  }
}

/// Global registry managing per-host concurrency profiles.
class HostConcurrencyRegistry {
  HostConcurrencyRegistry._();
  static final HostConcurrencyRegistry instance = HostConcurrencyRegistry._();

  final Map<String, HostConcurrencyProfile> _profiles = {};

  HostConcurrencyProfile profileFor(String urlOrHost) {
    String host = urlOrHost;
    if (urlOrHost.contains('://')) {
      final uri = Uri.tryParse(urlOrHost);
      host = uri?.host.isNotEmpty == true ? uri!.host : urlOrHost;
    }
    return _profiles.putIfAbsent(
      host.toLowerCase(),
      () => HostConcurrencyProfile(host.toLowerCase()),
    );
  }

  int getOptimalThreadsFor(String urlOrHost, {int maxLimit = 16}) {
    final profile = profileFor(urlOrHost);
    return min(profile.optimalThreads, maxLimit.clamp(1, 16));
  }

  void recordSpeed(String urlOrHost, double bytesPerSec, int threads) {
    final profile = profileFor(urlOrHost);
    profile.recordSpeed(bytesPerSec, threads);
  }

  void clear() {
    _profiles.clear();
  }
}
