import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import 'mirror_health_store.dart';

/// Orders a list of mirror URLs for best-first use.
///
/// Ranking rules:
///  1. Blacklisted mirrors always sort last.
///  2. Non-blacklisted mirrors are ranked by persisted speed (descending),
///     with a large penalty per persisted failure so flaky mirrors drop.
/// The given [primary] URL (if any) is always returned first when present in
/// [urls], before any ranking is applied.
List<String> orderMirrorUrls(List<String> urls, {String? primary}) {
  if (urls.length <= 1) return List.of(urls);

  final ordered = <String>[];
  if (primary != null && urls.contains(primary)) {
    ordered.add(primary);
  }

  final remaining = urls.where((u) => !ordered.contains(u)).toList();
  final scored = remaining.map((url) {
    var score = 0.0;
    if (MirrorHealthStore.isBlacklisted(url)) {
      score = -1000000.0;
    } else {
      score = MirrorHealthStore.getPersistedSpeed(url) -
          MirrorHealthStore.getFailureCount(url) * 100000.0;
    }
    return MapEntry(url, score);
  }).toList();

  scored.sort((a, b) => b.value.compareTo(a.value));
  ordered.addAll(scored.map((e) => e.key));
  return ordered;
}

/// Returns `true` when [error] should NOT be retried against another mirror.
///
/// Client errors (4xx) indicate the request itself is bad — a different
/// mirror serving the same file would fail identically, so we propagate.
bool isNonRetryableMirrorError(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status != null && status >= 400 && status < 500) return true;
    if (error.type == DioExceptionType.cancel) return true;
  }
  return false;
}

/// Runs [attempt] against each mirror in order until one succeeds.
///
/// Failures are recorded in [MirrorHealthStore]; successes reset health.
/// Returns the mirror URL that succeeded, or `null` when all mirrors failed.
/// Non-retryable errors (4xx / cancel) abort immediately.
class MirrorFailover {
  static final _log = Logger('MirrorFailover');

  final List<String> mirrorUrls;
  int mirrorSwitches = 0;
  String? _lastAttempted;

  MirrorFailover(List<String> urls, {String? primary})
      : mirrorUrls = orderMirrorUrls(urls, primary: primary);

  /// The mirror URL that was attempted last (or `null` before any attempt).
  String? get lastAttempted => _lastAttempted;

  /// Attempts [attempt] for each ordered mirror.
  ///
  /// `attempt` must throw on failure and return normally on success. When
  /// [onSwitch] is provided it is invoked whenever a non-primary mirror is
  /// used successfully.
  ///
  /// FIX-M7: [maxAttempts] caps how many mirrors will be tried. When omitted
  /// (or set to 0) all mirrors are tried. This prevents extremely long wait
  /// times when many mirrors are registered but most are unhealthy.
  Future<String?> run(
    Future<void> Function(String mirrorUrl) attempt, {
    void Function(int index, String mirrorUrl)? onSwitch,
    int maxAttempts = 0, // FIX-M7: 0 = unlimited (try all mirrors)
  }) async {
    final limit = maxAttempts > 0 ? maxAttempts : mirrorUrls.length;
    int attempted = 0;
    for (var i = 0; i < mirrorUrls.length && attempted < limit; i++) {
      final mirrorUrl = mirrorUrls[i];

      if (MirrorHealthStore.isBlacklisted(mirrorUrl)) {
        _log.fine('[MirrorFailover] Skipping blacklisted: $mirrorUrl');
        continue;
      }

      _lastAttempted = mirrorUrl;
      attempted++;
      try {
        await attempt(mirrorUrl);
        await MirrorHealthStore.recordSuccess(
          mirrorUrl,
          speedBps: 0,
        );
        if (i > 0) {
          mirrorSwitches++;
          _log.info('[MirrorFailover] Switched to mirror #$i: $mirrorUrl');
          onSwitch?.call(i, mirrorUrl);
        }
        return mirrorUrl;
      } catch (e) {
        final statusCode = e is DioException ? e.response?.statusCode ?? 0 : 0;
        await MirrorHealthStore.recordFailure(
          mirrorUrl,
          statusCode: statusCode,
        );
        _log.warning(
          '[MirrorFailover] Mirror failed: $mirrorUrl ($e)',
        );

        if (isNonRetryableMirrorError(e)) {
          _log.info(
            '[MirrorFailover] Non-retryable error (${e.runtimeType}) — '
            'aborting mirror loop',
          );
          return null;
        }
      }
    }

    _log.severe(
      '[MirrorFailover] All ${mirrorUrls.length} mirrors failed',
    );
    return null;
  }
}
