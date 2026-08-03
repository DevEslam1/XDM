import 'dart:math';

class ServerProfile {
  final String host;
  DateTime lastAccess = DateTime.now();
  Duration? lastRetryAfter;
  bool wasRateLimited = false;
  int successCount = 0;
  int failureCount = 0;
  final List<int> _responseTimes = [];

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

  void recordSuccess(int responseTimeMs) {
    lastAccess = DateTime.now();
    successCount++;
    _responseTimes.add(responseTimeMs);
    if (_responseTimes.length > 20) _responseTimes.removeAt(0);
    wasRateLimited = false;
  }

  void recordFailure(int statusCode, String? retryAfter) {
    lastAccess = DateTime.now();
    failureCount++;
    if (statusCode == 429 || statusCode == 503) {
      wasRateLimited = true;
      if (retryAfter != null) {
        final seconds = int.tryParse(retryAfter);
        if (seconds != null) {
          lastRetryAfter = Duration(seconds: seconds.clamp(1, 3600));
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

    return Duration(seconds: (pow(2, attemptNumber) * 5).toInt().clamp(5, 120));
  }

  static void _evictIfNeeded() {
    if (_profiles.length > _maxProfiles) {
      final oldest = _profiles.entries.reduce(
          (a, b) => a.value.lastAccess.isBefore(b.value.lastAccess) ? a : b);
      _profiles.remove(oldest.key);
    }
  }

  static void clear() {
    _profiles.clear();
  }
}
