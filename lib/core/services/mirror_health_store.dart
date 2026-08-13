import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists mirror health data across app restarts.
///
/// Bad mirrors stay deprioritized for a configurable TTL. Known-bad mirrors
/// are never retried immediately after an app restart; they are only retried
/// once their blacklist expires (or a successful probe clears them).
class MirrorHealthStore {
  static final _log = Logger('MirrorHealthStore');
  static const _storeKey = 'mirror_health_data';
  static const _blacklistTtl = Duration(hours: 6);
  static Map<String, _PersistedMirrorState>? _cache;

  /// Loads persisted health data from [SharedPreferences].
  /// Safe to call repeatedly; already-loaded data is refreshed from disk.
  static Future<void> init() async {
    await flushPending();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storeKey);
    if (raw == null) {
      _cache = {};
      return;
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _cache = map.map(
        (k, v) => MapEntry(k, _PersistedMirrorState.fromJson(v)),
      );
      final countBefore = _cache!.length;
      _cache!.removeWhere((_, state) => state.isExpired);
      if (_cache!.length != countBefore) {
        await _persist();
      }
    } catch (e) {
      _log.warning('Failed to decode mirror health data: $e');
      _cache = {};
    }
  }

  /// Record a failure for a mirror URL.
  static Future<void> recordFailure(String url, {int statusCode = 0}) async {
    _cache ??= {};
    final state = _cache!.putIfAbsent(url, () => _PersistedMirrorState());
    state.failures++;
    state.lastFailure = DateTime.now().millisecondsSinceEpoch;
    state.lastStatusCode = statusCode;

    // Blacklist if > 5 failures in the current session/window.
    if (state.failures >= 5) {
      state.blacklistedUntil =
          DateTime.now().add(_blacklistTtl).millisecondsSinceEpoch;
      _log.warning(
        '[MirrorHealth] Blacklisted $url for ${_blacklistTtl.inHours}h',
      );
    }
    await _persist();
  }

  /// Record a success — resets the failure count and clears blacklist.
  static Future<void> recordSuccess(String url, {double speedBps = 0.0}) async {
    _cache ??= {};
    final state = _cache!.putIfAbsent(url, () => _PersistedMirrorState());
    state.failures = 0;
    state.lastSuccess = DateTime.now().millisecondsSinceEpoch;
    state.averageSpeedBps = speedBps;
    state.blacklistedUntil = 0;
    await _persist();
  }

  /// Record speed for a mirror URL using a rolling average of the last 10 samples.
  static Future<void> recordSpeed(String url, double bytesPerSec) async {
    _cache ??= {};
    final state = _cache!.putIfAbsent(url, () => _PersistedMirrorState());
    state.speedSamples.add(bytesPerSec);
    if (state.speedSamples.length > 10) {
      state.speedSamples.removeAt(0);
    }
    state.averageSpeedBps =
        state.speedSamples.reduce((a, b) => a + b) / state.speedSamples.length;
    await _persist();
  }

  /// Get active mirror URLs ranked by average speed descending, excluding blacklisted mirrors.
  static List<String> getMirrorRanking() {
    if (_cache == null) return [];
    final valid = _cache!.entries.where((e) => !isBlacklisted(e.key)).toList();
    valid.sort(
        (a, b) => b.value.averageSpeedBps.compareTo(a.value.averageSpeedBps));
    return valid.map((e) => e.key).toList();
  }

  static const _rankingCacheKey = 'mirror_ranking_cache';
  static const _rankingTtlKey = 'mirror_ranking_cache_ttl';

  /// Persists the ranked mirror list to SharedPreferences with 1-hour TTL.
  static Future<void> persistMirrorRanking(List<String> rankedUrls) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_rankingCacheKey, jsonEncode(rankedUrls));
      await prefs.setInt(
        _rankingTtlKey,
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
    } catch (e) {
      _log.warning('Failed to persist mirror ranking: $e');
    }
  }

  /// Retrieves the cached mirror ranking if valid (within 1h TTL).
  static Future<List<String>?> getPersistedMirrorRanking() async {
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
    } catch (e) {
      return null;
    }
  }

  /// Check if a mirror is currently blacklisted.
  static bool isBlacklisted(String url) {
    final state = _cache?[url];
    if (state == null) return false;
    if (state.blacklistedUntil == 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now >= state.blacklistedUntil) {
      state.blacklistedUntil = 0;
      state.failures = 0;
      return false;
    }
    return true;
  }

  /// Get the persisted speed for ranking mirrors.
  static double getPersistedSpeed(String url) {
    return _cache?[url]?.averageSpeedBps ?? 0;
  }

  /// Get the persisted failure count for a mirror.
  static int getFailureCount(String url) {
    return _cache?[url]?.failures ?? 0;
  }

  static Timer? _persistTimer;
  static bool _persistPending = false;

  static Future<void> _persist() async {
    if (_cache == null || _persistPending) return;
    _persistPending = true;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 5), () async {
      _persistPending = false;
      await flushPending();
    });
  }

  static Future<void> flushPending() async {
    if (_cache == null) return;
    _persistTimer?.cancel();
    _persistTimer = null;
    _persistPending = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(_cache!.map((k, v) => MapEntry(k, v.toJson())));
      await prefs.setString(_storeKey, raw);
    } catch (e) {
      _log.warning('Failed to persist mirror health data: $e');
    }
  }

  /// Clear all persisted mirror health data.
  static Future<void> clear() async {
    _cache = {};
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storeKey);
    await prefs.remove(_rankingCacheKey);
    await prefs.remove(_rankingTtlKey);
  }
}

class _PersistedMirrorState {
  _PersistedMirrorState();

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

  factory _PersistedMirrorState.fromJson(Map<String, dynamic> json) {
    final s = _PersistedMirrorState();
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
