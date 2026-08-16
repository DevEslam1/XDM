import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../power_monitor.dart';
import '../service_registry.dart';
import '../shared_prefs_batcher.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Mirror Health Store & Persistence
// ═══════════════════════════════════════════════════════════════════════════

/// Persists mirror health data across app restarts with LRU cap of 200 entries.
class MirrorHealthStore implements DisposableService {
  MirrorHealthStore() {
    ServiceRegistry.register(this);
  }

  static final MirrorHealthStore instance = MirrorHealthStore();

  final Logger _log = Logger('MirrorHealthStore');
  static const String _storeKey = 'mirror_health_data';
  static const Duration _blacklistTtl = Duration(hours: 6);
  static const int maxEntries = 200;

  /// Access-ordered cache: reads/writes move the entry to the tail, so the
  /// head is always the least-recently-used entry to evict.
  LinkedHashMap<String, PersistedMirrorState>? _cache;
  Timer? _cleanupTimer;

  /// Single periodic write-coalescing flusher. All writes are batched and
  /// flushed at most once per 30s (or when explicitly flushed durably).
  Timer? _flushTimer;
  bool _dirty = false;
  bool _flushing = false;

  static const String _rankingCacheKey = 'mirror_ranking_cache';
  static const String _rankingTtlKey = 'mirror_ranking_cache_ttl';

  /// Clean up expired entries from in-memory cache and mark for persistence.
  Future<void> cleanupStaleEntries() async {
    if (_cache == null) return;
    final countBefore = _cache!.length;
    _cache!.removeWhere((_, state) => state.isExpired);
    if (_cache!.length != countBefore) {
      _markDirty();
    }
  }

  /// Loads persisted health data from [SharedPreferences].
  Future<void> init() async {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(hours: 6), (_) {
      cleanupStaleEntries();
    });
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storeKey);
    if (raw == null) {
      _cache = LinkedHashMap();
      return;
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _cache = LinkedHashMap<String, PersistedMirrorState>.from(
        map.map((k, v) => MapEntry(k, PersistedMirrorState.fromJson(v))),
      );
      await cleanupStaleEntries();
    } catch (e) {
      _log.warning('Failed to decode mirror health data: $e');
      _cache = LinkedHashMap();
    }
  }

  /// Record a failure for a mirror URL. In-memory update only; the shared
  /// prefs write is coalesced by the periodic flusher.
  Future<void> recordFailure(String url, {int statusCode = 0}) async {
    _cache ??= LinkedHashMap();
    final state = _cache!.putIfAbsent(url, () => PersistedMirrorState());
    state.failures++;
    state.lastFailure = DateTime.now().millisecondsSinceEpoch;
    state.lastStatusCode = statusCode;
    _touch(url);

    if (state.failures >= 5) {
      state.blacklistedUntil =
          DateTime.now().add(_blacklistTtl).millisecondsSinceEpoch;
      _log.warning(
        '[MirrorHealth] Blacklisted $url for ${_blacklistTtl.inHours}h',
      );
    }
    _evictLruIfNeeded();
    _markDirty();
  }

  /// Record a success — resets the failure count and clears blacklist.
  Future<void> recordSuccess(String url, {double speedBps = 0.0}) async {
    _cache ??= LinkedHashMap();
    final state = _cache!.putIfAbsent(url, () => PersistedMirrorState());
    state.failures = 0;
    state.lastSuccess = DateTime.now().millisecondsSinceEpoch;
    state.averageSpeedBps = speedBps;
    state.blacklistedUntil = 0;
    _touch(url);
    _evictLruIfNeeded();
    _markDirty();
  }

  /// Record speed for a mirror URL using a rolling average of the last 10 samples.
  Future<void> recordSpeed(String url, double bytesPerSec) async {
    _cache ??= LinkedHashMap();
    final state = _cache!.putIfAbsent(url, () => PersistedMirrorState());
    state.speedSamples.add(bytesPerSec);
    if (state.speedSamples.length > 10) {
      state.speedSamples.removeAt(0);
    }
    state.averageSpeedBps =
        state.speedSamples.reduce((a, b) => a + b) / state.speedSamples.length;
    _touch(url);
    _evictLruIfNeeded();
    _markDirty();
  }

  /// Get active mirror URLs ranked by average speed descending, excluding blacklisted mirrors.
  List<String> getMirrorRanking() {
    if (_cache == null) return [];
    // Snapshot entries first: isBlacklisted() -> _touch() mutates the map.
    final valid =
        _cache!.entries.toList().where((e) => !isBlacklisted(e.key)).toList();
    valid.sort(
        (a, b) => b.value.averageSpeedBps.compareTo(a.value.averageSpeedBps));
    return valid.map((e) => e.key).toList();
  }

  /// Persists the ranked mirror list to SharedPreferences with 1-hour TTL.
  Future<void> persistMirrorRanking(List<String> rankedUrls) async {
    try {
      SharedPrefsBatcher.instance
          .setString(_rankingCacheKey, jsonEncode(rankedUrls));
      SharedPrefsBatcher.instance.setInt(
        _rankingTtlKey,
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
      await SharedPrefsBatcher.instance.flush();
    } catch (e) {
      _log.warning('Failed to persist mirror ranking: $e');
    }
  }

  /// Retrieves the cached mirror ranking if valid (within 1h TTL).
  Future<List<String>?> getPersistedMirrorRanking() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ttl = prefs.getInt(_rankingTtlKey) ?? 0;
      if (DateTime.now().millisecondsSinceEpoch > ttl) {
        return null;
      }
      final raw = prefs.getString(_rankingCacheKey);
      if (raw == null) return null;
      final list = jsonDecode(raw) as List<dynamic>;
      return list.cast<String>();
    } catch (e, st) {
      LoggingService.logger('MirrorRegistry')
          .warning('Operation failed with fallback', e, st);
      return null;
    }
  }

  /// Check if a mirror is currently blacklisted.
  bool isBlacklisted(String url) {
    final state = _cache?[url];
    if (state == null) return false;
    _touch(url);
    if (state.blacklistedUntil == 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now >= state.blacklistedUntil) {
      state.blacklistedUntil = 0;
      state.failures = 0;
      return false;
    }
    return true;
  }

  double getPersistedSpeed(String url) {
    final state = _cache?[url];
    if (state == null) return 0;
    _touch(url);
    return state.averageSpeedBps;
  }

  int getFailureCount(String url) {
    final state = _cache?[url];
    if (state == null) return 0;
    _touch(url);
    return state.failures;
  }

  /// Moves [key] to the tail of the access-order map.
  void _touch(String key) {
    final cache = _cache;
    if (cache == null) return;
    final value = cache.remove(key);
    if (value != null) cache[key] = value;
  }

  void _evictLruIfNeeded() {
    if (_cache == null || _cache!.length <= maxEntries) return;
    // LinkedHashMap preserves insertion (and touch) order; head = LRU.
    _cache!.remove(_cache!.keys.first);
  }

  /// Marks state dirty and schedules a 30s flush if not already pending.
  void _markDirty() {
    _dirty = true;
    _flushTimer ??= Timer(const Duration(seconds: 30), () {
      _flushTimer = null;
      if (_dirty) {
        flushPending();
      }
    });
  }

  /// Flushes the coalesced state to SharedPreferences. Skipped while the
  /// screen is off unless [durable] is set (final explicit save).
  Future<void> flushPending({bool durable = false}) async {
    if (_cache == null || !_dirty || _flushing) return;
    if (PowerMonitor.screenOff && !durable) {
      _log.fine(
          '[MirrorHealth] Skipping flush while screen is off (non-durable)');
      return;
    }
    _flushing = true;
    try {
      final raw = jsonEncode(_cache!.map((k, v) => MapEntry(k, v.toJson())));
      SharedPrefsBatcher.instance.setString(_storeKey, raw);
      if (durable) {
        await SharedPrefsBatcher.instance.flush();
      }
      _dirty = false;
      _flushTimer?.cancel();
      _flushTimer = null;
    } catch (e) {
      _log.warning('Failed to persist mirror health data: $e');
    } finally {
      _flushing = false;
    }
  }

  Future<void> clear() async {
    _cache = LinkedHashMap();
    _dirty = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storeKey);
    await prefs.remove(_rankingCacheKey);
    await prefs.remove(_rankingTtlKey);
  }

  @override
  Future<void> dispose() async {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    await flushPending(durable: true);
  }

  // Static convenience wrappers delegating to singleton instance
  static Future<void> staticInit() => instance.init();
  static Future<void> staticRecordFailure(String url, {int statusCode = 0}) =>
      instance.recordFailure(url, statusCode: statusCode);
  static Future<void> staticRecordSuccess(String url,
          {double speedBps = 0.0}) =>
      instance.recordSuccess(url, speedBps: speedBps);
  static Future<void> staticRecordSpeed(String url, double bytesPerSec) =>
      instance.recordSpeed(url, bytesPerSec);
  static List<String> staticGetMirrorRanking() => instance.getMirrorRanking();
  static bool staticIsBlacklisted(String url) => instance.isBlacklisted(url);
  static double staticGetPersistedSpeed(String url) =>
      instance.getPersistedSpeed(url);
  static int staticGetFailureCount(String url) => instance.getFailureCount(url);
  static Future<void> staticClear() => instance.clear();
}

class PersistedMirrorState {
  PersistedMirrorState();

  int failures = 0;
  int lastFailure = 0;
  int lastSuccess = 0;
  int lastStatusCode = 0;
  int blacklistedUntil = 0;
  double averageSpeedBps = 0;
  List<double> speedSamples = [];

  bool get isExpired =>
      blacklistedUntil > 0 &&
      DateTime.now().millisecondsSinceEpoch > blacklistedUntil;

  Map<String, dynamic> toJson() => {
        'failures': failures,
        'lastFailure': lastFailure,
        'lastSuccess': lastSuccess,
        'lastStatusCode': lastStatusCode,
        'blacklistedUntil': blacklistedUntil,
        'averageSpeedBps': averageSpeedBps,
        'speedSamples': speedSamples,
      };

  factory PersistedMirrorState.fromJson(Map<String, dynamic> json) {
    final s = PersistedMirrorState();
    s.failures = json['failures'] as int? ?? 0;
    s.lastFailure = json['lastFailure'] as int? ?? 0;
    s.lastSuccess = json['lastSuccess'] as int? ?? 0;
    s.lastStatusCode = json['lastStatusCode'] as int? ?? 0;
    s.blacklistedUntil = json['blacklistedUntil'] as int? ?? 0;
    s.averageSpeedBps = (json['averageSpeedBps'] as num?)?.toDouble() ?? 0;
    if (json['speedSamples'] != null) {
      s.speedSamples = (json['speedSamples'] as List<dynamic>)
          .map((e) => (e as num).toDouble())
          .toList();
    }
    return s;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Server Profile Manager
// ═══════════════════════════════════════════════════════════════════════════

class ServerProfile {
  final String host;
  DateTime lastAccess = DateTime.now();
  Duration? lastRetryAfter;
  bool wasRateLimited = false;
  bool supportsRange = true;
  int successCount = 0;
  int failureCount = 0;
  static const Duration profileTtl = Duration(days: 7);
  final Queue<({int timestampMs, int timeMs})> _responseTimes = Queue();

  ServerProfile({required this.host});

  bool get isExpired => DateTime.now().difference(lastAccess) > profileTtl;

  void pruneStaleMetrics() {
    final cutoff = DateTime.now().subtract(profileTtl).millisecondsSinceEpoch;
    _responseTimes.removeWhere((item) => item.timestampMs < cutoff);
  }

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

  int get avgResponseTimeMs {
    pruneStaleMetrics();
    return _responseTimes.isEmpty
        ? 0
        : (_responseTimes.map((e) => e.timeMs).reduce((a, b) => a + b) /
                _responseTimes.length)
            .round();
  }

  double get reliabilityScore => successRate * 100.0 - failureCount;

  void recordSuccess(int responseTimeMs) {
    lastAccess = DateTime.now();
    successCount++;
    pruneStaleMetrics();
    _responseTimes.add((
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      timeMs: responseTimeMs
    ));
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
          } catch (e, st) {
            LoggingService.logger('MirrorRegistry')
                .warning('Operation failed', e, st);
          }
        }
      }
    }
  }
}

class ServerProfileManager
    implements DisposableService, MemoryPressureListener {
  ServerProfileManager() {
    ServiceRegistry.register(this);
    ServiceRegistry.registerMemoryPressureListener(this);
  }

  static final ServerProfileManager instance = ServerProfileManager();

  final Map<String, ServerProfile> _profiles = {};
  static const _maxProfiles = 100;

  /// FIX-P1-05: Eviction index keyed by eviction score (lastAccess +
  /// reliability bonus). Finding the least-recently-used profile becomes
  /// O(log n) instead of the previous O(n) reduce() inside a while loop.
  final SplayTreeMap<int, Set<String>> _evictionIndex =
      SplayTreeMap<int, Set<String>>();

  ServerProfile getProfile(String url) {
    _evictIfNeeded();
    final host = Uri.tryParse(url)?.host ?? url;
    final existing = _profiles[host];
    if (existing != null) return existing;
    final profile = ServerProfile(host: host);
    _profiles[host] = profile;
    _indexProfile(profile);
    return profile;
  }

  int _scoreFor(ServerProfile profile) =>
      profile.lastAccess.millisecondsSinceEpoch +
      (profile.reliabilityScore * 1000).round();

  void _indexProfile(ServerProfile profile) {
    final score = _scoreFor(profile);
    _evictionIndex.putIfAbsent(score, () => <String>{}).add(profile.host);
  }

  void _unindexProfile(ServerProfile profile) {
    final score = _scoreFor(profile);
    final bucket = _evictionIndex[score];
    if (bucket == null) return;
    bucket.remove(profile.host);
    if (bucket.isEmpty) {
      _evictionIndex.remove(score);
    }
  }

  ({double successRate, int avgResponseTimeMs, bool supportsRange})
      getProfileForMirrorSelection(String url) {
    final profile = getProfile(url);
    return (
      successRate: profile.successRate,
      avgResponseTimeMs: profile.avgResponseTimeMs,
      supportsRange: profile.supportsRange,
    );
  }

  void recordSuccess(String url, {required int responseTimeMs}) {
    final profile = getProfile(url);
    _unindexProfile(profile);
    profile.recordSuccess(responseTimeMs);
    _indexProfile(profile);
    _evictIfNeeded();
  }

  void recordFailure(
    String url, {
    required int statusCode,
    required String? retryAfter,
  }) {
    final profile = getProfile(url);
    _unindexProfile(profile);
    profile.recordFailure(statusCode, retryAfter);
    _indexProfile(profile);
    _evictIfNeeded();
  }

  Duration getRetryDelay(String url, int attemptNumber) {
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

  void _evictIfNeeded() {
    final now = DateTime.now();
    final expired = _profiles.entries
        .where((e) =>
            now.difference(e.value.lastAccess) > ServerProfile.profileTtl)
        .toList();
    for (final entry in expired) {
      _unindexProfile(entry.value);
      _profiles.remove(entry.key);
    }
    while (_profiles.length > _maxProfiles) {
      if (_evictionIndex.isEmpty) break;
      final lowestScore = _evictionIndex.firstKey();
      final bucket = _evictionIndex[lowestScore];
      if (bucket == null || bucket.isEmpty) {
        _evictionIndex.remove(lowestScore);
        continue;
      }
      final host = bucket.first;
      bucket.remove(host);
      if (bucket.isEmpty) {
        _evictionIndex.remove(lowestScore);
      }
      _profiles.remove(host);
    }
  }

  void clear() {
    _profiles.clear();
    _evictionIndex.clear();
  }

  @override
  void onMemoryPressure() {
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    final stale = _profiles.entries
        .where((e) => e.value.lastAccess.isBefore(cutoff))
        .toList();
    for (final entry in stale) {
      _unindexProfile(entry.value);
      _profiles.remove(entry.key);
    }
  }

  @override
  Future<void> dispose() async {
    ServiceRegistry.unregister(this);
    ServiceRegistry.unregisterMemoryPressureListener(this);
    _profiles.clear();
    _evictionIndex.clear();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Mirror Benchmark Service
// ═══════════════════════════════════════════════════════════════════════════

class MirrorBenchmarkService
    implements DisposableService, MemoryPressureListener {
  MirrorBenchmarkService() {
    ServiceRegistry.register(this);
    ServiceRegistry.registerMemoryPressureListener(this);
  }

  static final MirrorBenchmarkService instance = MirrorBenchmarkService();

  static final _log = Logger('MirrorBenchmark');
  final Map<String, _BenchmarkResult> _results = {};
  static const _cacheTtl = Duration(hours: 1);
  static const _benchmarkBytes = 128 * 1024;
  static const _earlyAbortBytes = 64 * 1024;
  static const double _fastSpeedThreshold = 5 * 1024 * 1024.0;
  static const _maxCacheSize = 50;
  static const int _maxConcurrentBenchmarks = 3;

  Future<List<MirrorBenchmarkResult>> benchmarkAll(
    List<String> urls,
  ) async {
    if (urls.isEmpty) return [];

    final results = List<MirrorBenchmarkResult?>.filled(urls.length, null);
    var nextIndex = 0;

    // Performance Optimization: Concurrency pool limiting concurrent benchmark
    // requests to a maximum of 3 at a time to prevent OS socket exhaustion.
    Future<void> worker() async {
      while (true) {
        final i = nextIndex++;
        if (i >= urls.length) break;
        final url = urls[i];
        try {
          results[i] = await _benchmarkSingle(url);
        } catch (e) {
          _log.warning('[Benchmark] Failed for $url: $e');
          results[i] = MirrorBenchmarkResult(
            url: url,
            latencyMs: 99999,
            speedBps: 0,
            success: false,
          );
        }
      }
    }

    final poolSize = min(_maxConcurrentBenchmarks, urls.length);
    final workers = List.generate(poolSize, (_) => worker());
    await Future.wait(workers);

    final ranked = results.whereType<MirrorBenchmarkResult>().toList()
      ..sort((a, b) {
        if (a.success != b.success) return a.success ? -1 : 1;
        return a.latencyMs.compareTo(b.latencyMs);
      });
    return ranked;
  }

  void clearCache() => _results.clear();

  @override
  void onMemoryPressure() {
    clearCache();
  }

  @override
  Future<void> dispose() async {
    ServiceRegistry.unregister(this);
    ServiceRegistry.unregisterMemoryPressureListener(this);
    clearCache();
  }

  Future<MirrorBenchmarkResult> _benchmarkSingle(String url) async {
    final cached = _results[url];
    if (cached != null && !cached.isExpired) {
      return cached.toResult(url);
    }

    final stopwatch = Stopwatch()..start();
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 10),
      ),
    );
    final cancelToken = CancelToken();

    try {
      await dio.head(url, options: Options(validateStatus: (_) => true));
      final ttfb = stopwatch.elapsedMilliseconds;
      stopwatch.reset();

      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          headers: {'Range': 'bytes=0-${_benchmarkBytes - 1}'},
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
        ),
      );

      int bytesReceived = 0;
      try {
        await for (final chunk in response.data!.stream) {
          bytesReceived += chunk.length;
          if (bytesReceived >= _earlyAbortBytes) {
            final elapsed = stopwatch.elapsedMilliseconds;
            if (elapsed > 0) {
              final currentSpeed = bytesReceived * 1000.0 / elapsed;
              if (currentSpeed > _fastSpeedThreshold) {
                break;
              }
            }
          }
          if (bytesReceived >= _benchmarkBytes) {
            break;
          }
        }
      } finally {
        if (!cancelToken.isCancelled) {
          cancelToken.cancel('benchmark_complete');
        }
      }

      final downloadMs = stopwatch.elapsedMilliseconds;
      final speedBps =
          downloadMs > 0 ? (bytesReceived * 1000.0 / downloadMs) : 0.0;

      final result = _BenchmarkResult(
        ttfbMs: ttfb,
        downloadMs: downloadMs,
        speedBps: speedBps,
        timestamp: DateTime.now(),
      );

      if (_results.length >= _maxCacheSize) {
        _results.remove(_results.keys.first);
      }
      _results[url] = result;

      return result.toResult(url);
    } finally {
      dio.close();
    }
  }
}

class MirrorBenchmarkResult {
  final String url;
  final int latencyMs;
  final double speedBps;
  final bool success;

  const MirrorBenchmarkResult({
    required this.url,
    required this.latencyMs,
    required this.speedBps,
    required this.success,
  });
}

class _BenchmarkResult {
  final int ttfbMs;
  final int downloadMs;
  final double speedBps;
  final DateTime timestamp;

  _BenchmarkResult({
    required this.ttfbMs,
    required this.downloadMs,
    required this.speedBps,
    required this.timestamp,
  });

  bool get isExpired =>
      DateTime.now().difference(timestamp) > MirrorBenchmarkService._cacheTtl;

  MirrorBenchmarkResult toResult(String url) => MirrorBenchmarkResult(
        url: url,
        latencyMs: ttfbMs,
        speedBps: speedBps,
        success: true,
      );
}

// ═══════════════════════════════════════════════════════════════════════════
// Mirror Registry Unified Facade
// ═══════════════════════════════════════════════════════════════════════════

class MirrorRegistry implements DisposableService {
  final MirrorHealthStore healthStore;

  MirrorRegistry({MirrorHealthStore? healthStore})
      : healthStore = healthStore ?? MirrorHealthStore.instance;

  Future<void> init() => healthStore.init();

  @override
  Future<void> dispose() => healthStore.dispose();
}
