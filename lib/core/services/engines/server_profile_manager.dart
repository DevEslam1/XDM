import 'dart:collection';
import 'dart:io';
import 'dart:math';

class ServerProfile {
  final String host;
  DateTime lastAccess = DateTime.now();
  Duration? lastRetryAfter;
  bool wasRateLimited = false;
  bool supportsRange = true;
  int successCount = 0;
  int failureCount = 0;
  final Queue<int> _responseTimes = Queue<int>();

  ServerProfile({required this.host});

  bool get isCdn {
    const cdnPatterns = [
      'cloudflare',
      'fastly',
      'akamai',
      'cloudfront',
      'cdn',
      'edgekey'
    ];
    return cdnPatterns.any((p) => host.toLowerCase().contains(p));
  }

  double get successRate => (successCount + failureCount) > 0
      ? successCount / (successCount + failureCount)
      : 1.0;

  int get avgResponseTimeMs => _responseTimes.isEmpty
      ? 0
      : (_responseTimes.reduce((a, b) => a + b) / _responseTimes.length)
          .round();

  double get reliabilityScore => successRate * 100.0 - failureCount;

  void recordSuccess(int responseTimeMs) {
    lastAccess = DateTime.now();
    successCount++;
    _responseTimes.add(responseTimeMs);
    if (_responseTimes.length > 20) _responseTimes.removeFirst();
    wasRateLimited = false;
  }

  void recordFailure(int statusCode, String? retryAfter) {
    lastAccess = DateTime.now();
    failureCount++;
    if (statusCode == 429 || statusCode == 503) {
      wasRateLimited = true;
      if (retryAfter != null) {
        final trimmed = retryAfter.trim();
        final seconds = int.tryParse(trimmed);
        if (seconds != null) {
          lastRetryAfter = Duration(seconds: seconds.clamp(1, 3600));
        } else {
          try {
            final date = HttpDate.parse(trimmed);
            final diff = date.difference(DateTime.now()).inSeconds;
            if (diff > 0) {
              lastRetryAfter = Duration(seconds: diff.clamp(1, 3600));
            }
          } catch (_) {}
        }
      }
    }
  }
}

class ServerProfileManager {
  static final Map<String, ServerProfile> _profiles = {};
  static const _maxProfiles = 100;

  static ServerProfile getProfile(String url) {
    final host = Uri.tryParse(url)?.host ?? url;
    return _profiles.putIfAbsent(host, () => ServerProfile(host: host));
  }

  static ({double successRate, int avgResponseTimeMs, bool supportsRange})
      getProfileForMirrorSelection(String url) {
    final profile = getProfile(url);
    return (
      successRate: profile.successRate,
      avgResponseTimeMs: profile.avgResponseTimeMs,
      supportsRange: profile.supportsRange,
    );
  }

  static void recordSuccess(String url, {required int responseTimeMs}) {
    final profile = getProfile(url);
    profile.recordSuccess(responseTimeMs);
    _evictIfNeeded();
  }

  static void recordFailure(
    String url, {
    required int statusCode,
    required String? retryAfter,
  }) {
    final profile = getProfile(url);
    profile.recordFailure(statusCode, retryAfter);
    _evictIfNeeded();
  }

  static Duration getRetryDelay(String url, int attemptNumber) {
    final profile = getProfile(url);

    if (profile.lastRetryAfter != null) {
      return profile.lastRetryAfter!;
    }

    if (profile.isCdn) {
      return Duration(seconds: (attemptNumber * 2).clamp(1, 10));
    }

    if (profile.wasRateLimited) {
      return Duration(seconds: (attemptNumber * 30).clamp(30, 300));
    }

    final safeAttempt = attemptNumber.clamp(0, 20);
    return Duration(seconds: (pow(2, safeAttempt) * 5).toInt().clamp(5, 120));
  }

  static void _evictIfNeeded() {
    while (_profiles.length > _maxProfiles) {
      final toEvict = _profiles.entries.reduce((a, b) {
        final scoreA = a.value.lastAccess.millisecondsSinceEpoch +
            (a.value.reliabilityScore * 1000).round();
        final scoreB = b.value.lastAccess.millisecondsSinceEpoch +
            (b.value.reliabilityScore * 1000).round();
        return scoreA < scoreB ? a : b;
      });
      _profiles.remove(toEvict.key);
    }
  }

  static void clear() {
    _profiles.clear();
  }
}
