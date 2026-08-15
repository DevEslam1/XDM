import 'dart:async';
import 'dart:collection';
import 'dart:math' show max;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import '../circuit_breaker.dart';
import '../protocol_cache.dart';
import '../retry_engine.dart';
import 'mirror_registry.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Mirror Manager & Mirror Stats
// ═══════════════════════════════════════════════════════════════════════════

class MirrorManager {
  static final _log = Logger('MirrorManager');
  static const int maxFailuresBeforeDeprioritize = 3;

  final List<MirrorStats> _mirrors;

  MirrorManager(List<String> urls)
      : _mirrors = urls.map((u) => MirrorStats(u)).toList();

  String? get primaryUrl => _mirrors.isNotEmpty ? _mirrors.first.url : null;

  List<String> get allUrls => _mirrors.map((m) => m.url).toList();

  String? getBestMirror() {
    if (_mirrors.isEmpty) return null;
    final healthy = _mirrors
        .where((m) => m.failures < maxFailuresBeforeDeprioritize)
        .toList();
    if (healthy.isEmpty) return _mirrors.first.url;
    healthy.sort((a, b) => b.avgSpeedBps.compareTo(a.avgSpeedBps));
    return healthy.first.url;
  }

  String? getNextMirror(String excludeUrl) {
    final candidates = _mirrors
        .where(
          (m) =>
              m.url != excludeUrl && m.failures < maxFailuresBeforeDeprioritize,
        )
        .toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.avgSpeedBps.compareTo(a.avgSpeedBps));
    return candidates.first.url;
  }

  void recordSuccess(String url, int bytes, Duration elapsed) {
    final mirror = _find(url);
    if (mirror == null) return;
    mirror.totalBytes += bytes;
    mirror.totalMs += elapsed.inMilliseconds;
    mirror.failures = 0;
    mirror.lastUsed = DateTime.now();
  }

  void recordFailure(String url) {
    final mirror = _find(url);
    if (mirror == null) return;
    mirror.failures++;
    mirror.lastUsed = DateTime.now();
    _log.warning('Mirror $url failure #${mirror.failures}');
  }

  bool isHealthy(String url) {
    final mirror = _find(url);
    return mirror != null && mirror.failures < maxFailuresBeforeDeprioritize;
  }

  MirrorStats? _find(String url) {
    for (final m in _mirrors) {
      if (m.url == url) return m;
    }
    return null;
  }
}

class MirrorStats {
  final String url;
  int totalBytes = 0;
  int totalMs = 0;
  int failures = 0;
  DateTime? lastUsed;

  MirrorStats(this.url);

  static const double _maxAvgSpeedBps = 10 * 1024 * 1024 * 1024; // 10 GiB/s

  double get avgSpeedBps {
    if (totalMs <= 0) return 0;
    final raw = totalBytes / totalMs * 1000;
    return raw > _maxAvgSpeedBps ? _maxAvgSpeedBps : raw;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Mirror Parallel Engine
// ═══════════════════════════════════════════════════════════════════════════

class _MirrorState {
  final Queue<double> _speeds = Queue<double>();
  double get averageSpeed =>
      _speeds.isEmpty ? 0 : _speeds.reduce((a, b) => a + b) / _speeds.length;

  void updateSpeed(double speed) {
    _speeds.add(speed);
    if (_speeds.length > 10) _speeds.removeFirst();
  }
}

class MirrorParallelEngine {
  static final _log = Logger('MirrorParallelEngine');
  final List<String> _mirrorUrls;
  final Map<String, _MirrorState> _mirrorStates = {};
  static const int maxMirrorStates = 50;
  MirrorFailover? failover;

  MirrorParallelEngine(this._mirrorUrls, {this.failover});

  static Future<T> raceMirrors<T>(
    List<String> urls,
    Future<T> Function(String url, CancelToken cancelToken) fetch,
  ) async {
    if (urls.isEmpty) {
      throw ArgumentError('No mirror URLs provided for race');
    }
    if (urls.length == 1) {
      final token = CancelToken();
      return fetch(urls.first, token);
    }

    final completer = Completer<T>();
    final tokens = <CancelToken>[];
    int failures = 0;

    for (final url in urls) {
      final token = CancelToken();
      tokens.add(token);
      fetch(url, token).then((result) {
        if (!completer.isCompleted) {
          completer.complete(result);
          for (final t in tokens) {
            if (t != token && !t.isCancelled) {
              t.cancel('mirror_race_winner_found');
            }
          }
        }
      }).catchError((dynamic err) {
        failures++;
        if (failures >= urls.length && !completer.isCompleted) {
          completer.completeError(
            err ?? Exception('All mirrors failed during race'),
          );
        }
      });
    }

    return completer.future;
  }

  List<String> get mirrorUrls => List.unmodifiable(_mirrorUrls);

  int? _cachedTotalThreads;
  Map<String, List<int>>? _cachedDistribution;

  void _invalidateThreadDistributionCache() {
    _cachedDistribution = null;
    _cachedTotalThreads = null;
  }

  Map<String, List<int>> distributeThreads(int totalThreads) {
    if (_mirrorUrls.isEmpty || totalThreads <= 0) return {};
    if (_cachedTotalThreads == totalThreads && _cachedDistribution != null) {
      return Map<String, List<int>>.from(
        _cachedDistribution!.map((k, v) => MapEntry(k, List<int>.from(v))),
      );
    }

    final distribution = <String, List<int>>{};
    final activeMirrorCount = _mirrorUrls.length.clamp(0, totalThreads);
    final activeMirrors = _mirrorUrls.take(activeMirrorCount).toList();
    final threadsPerMirror = totalThreads ~/ activeMirrors.length;
    var remainder = totalThreads % activeMirrors.length;

    var threadIndex = 0;
    for (final mirror in activeMirrors) {
      final count = threadsPerMirror + (remainder > 0 ? 1 : 0);
      if (remainder > 0) remainder--;
      distribution[mirror] = List.generate(count, (_) => threadIndex++);
    }

    if (_mirrorStates.length > 1) {
      final avgSpeed = _mirrorStates.values
              .map((s) => s.averageSpeed)
              .reduce((a, b) => a + b) /
          _mirrorStates.length;

      if (avgSpeed > 0) {
        final slowMirrors = distribution.keys.where((m) {
          final s = _mirrorStates[m];
          return s != null &&
              s.averageSpeed > 0 &&
              s.averageSpeed < avgSpeed * 0.33;
        }).toList();

        if (slowMirrors.isNotEmpty) {
          final fastestEntry = _mirrorStates.entries.reduce(
              (a, b) => a.value.averageSpeed > b.value.averageSpeed ? a : b);
          final fastestMirror = fastestEntry.key;

          for (final slowMirror in slowMirrors) {
            if (slowMirror != fastestMirror &&
                distribution.containsKey(slowMirror)) {
              final threadsToReallocate = distribution.remove(slowMirror) ?? [];
              if (threadsToReallocate.isNotEmpty) {
                distribution.putIfAbsent(fastestMirror, () => []);
                distribution[fastestMirror]!.addAll(threadsToReallocate);
                _log.info(
                  '[MirrorParallel] Reallocated ${threadsToReallocate.length} threads from slow mirror $slowMirror to fastest $fastestMirror',
                );
                failover?.reportSlowMirror(slowMirror, fastestMirror);
              }
            }
          }
        }
      }
    }

    _cachedTotalThreads = totalThreads;
    _cachedDistribution = distribution;
    return Map<String, List<int>>.from(
      distribution.map((k, v) => MapEntry(k, List<int>.from(v))),
    );
  }

  Timer? _cacheInvalidateDebounce;

  void reportMirrorSpeed(String mirrorUrl, double bytesPerSecond) {
    // Move the mirror to the tail (most-recently-used), evicting the LRU
    // entry once the map exceeds the cap to keep memory bounded on jobs that
    // probe many transient mirror URLs.
    final existing = _mirrorStates.remove(mirrorUrl);
    final state = existing ?? _MirrorState();
    _mirrorStates[mirrorUrl] = state;
    while (_mirrorStates.length > maxMirrorStates) {
      _mirrorStates.remove(_mirrorStates.keys.first);
    }
    state.updateSpeed(bytesPerSecond);

    _cacheInvalidateDebounce?.cancel();
    _cacheInvalidateDebounce = Timer(const Duration(seconds: 2), () {
      _invalidateThreadDistributionCache();
    });

    if (_mirrorStates.length > 1) {
      final avgSpeed = _mirrorStates.values
              .map((s) => s.averageSpeed)
              .reduce((a, b) => a + b) /
          _mirrorStates.length;

      if (state.averageSpeed < avgSpeed * 0.33 && state.averageSpeed > 0) {
        _logSlowMirrorDetected(mirrorUrl);
      }
    }
  }

  void _logSlowMirrorDetected(String slowMirror) {
    final slowState = _mirrorStates[slowMirror];
    final fastest = _mirrorStates.entries
        .reduce((a, b) => a.value.averageSpeed > b.value.averageSpeed ? a : b);
    _log.info(
      '[MirrorParallel] Slow mirror detected: $slowMirror '
      '(avg ${((slowState?.averageSpeed ?? 0) / 1024).toStringAsFixed(0)} KB/s). '
      'Reallocating threads to fastest mirror: ${fastest.key} '
      '(avg ${(fastest.value.averageSpeed / 1024).toStringAsFixed(0)} KB/s).',
    );
    failover?.reportSlowMirror(slowMirror, fastest.key);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Mirror Failover & Ordering
// ═══════════════════════════════════════════════════════════════════════════

List<String> orderMirrorUrls(List<String> urls, {String? primary}) {
  final list = List<String>.from(
      urls.where((u) => u.startsWith('http://') || u.startsWith('https://')));
  list.sort((a, b) {
    if (a == primary) return -1;
    if (b == primary) return 1;
    final blackA = MirrorHealthStore.instance.isBlacklisted(a);
    final blackB = MirrorHealthStore.instance.isBlacklisted(b);
    if (blackA != blackB) return blackA ? 1 : -1;
    final speedA = MirrorHealthStore.instance.getPersistedSpeed(a);
    final speedB = MirrorHealthStore.instance.getPersistedSpeed(b);
    return speedB.compareTo(speedA);
  });
  return list;
}

class MirrorFailover {
  MirrorFailover(List<String> urls)
      : _urls = List<String>.unmodifiable(
          urls
              .where((u) => u.startsWith('http://') || u.startsWith('https://'))
              .toList(),
        );

  final List<String> _urls;
  int _index = 0;
  int _switches = 0;
  ProtocolSupport? _protocolHint;

  final Map<String, CircuitBreaker> _circuits = {};

  String get activeUrl => _urls.isEmpty ? '' : _urls[_index];
  bool get hasAlternatives => _urls.length > 1;
  int get remainingAlternatives => _urls.length - 1 - _index;
  int get mirrorSwitches => _switches;
  ProtocolSupport? get protocolHint => _protocolHint;

  int _compareCandidates(String urlA, String urlB) {
    final speedA = MirrorHealthStore.instance.getPersistedSpeed(urlA);
    final speedB = MirrorHealthStore.instance.getPersistedSpeed(urlB);

    final protoA = ProtocolCache.get(urlA);
    final protoB = ProtocolCache.get(urlB);

    final maxSpeed = max(speedA, speedB);
    if (maxSpeed > 0) {
      final diffRatio = (speedA - speedB).abs() / maxSpeed;
      if (diffRatio <= 0.15) {
        final isH2A =
            protoA == ProtocolSupport.http2 || protoA == ProtocolSupport.http3;
        final isH2B =
            protoB == ProtocolSupport.http2 || protoB == ProtocolSupport.http3;
        if (isH2A != isH2B) {
          return isH2A ? -1 : 1;
        }
      }
    }

    return speedB.compareTo(speedA);
  }

  Future<void> reportSuccess({double speedBps = 0.0}) async {
    if (_urls.isEmpty) return;
    await MirrorHealthStore.instance.recordSuccess(_urls[_index], speedBps: speedBps);
  }

  String? advance() {
    if (_urls.isEmpty) return null;

    final validUrls =
        _urls.where((u) => !MirrorHealthStore.instance.isBlacklisted(u)).toList();
    final candidates =
        validUrls.isNotEmpty ? validUrls : List<String>.from(_urls);

    var available = candidates.where((u) {
      final cb = _circuits.putIfAbsent(
        u,
        () => CircuitBreaker(
          failureThreshold: 3,
          openTimeout: const Duration(minutes: 30),
        ),
      );
      return cb.allowRequest();
    }).toList();

    if (available.isEmpty) {
      debugPrint(
        '[MirrorFailover] Warning: All mirror circuits open! Falling back to round-robin.',
      );
      available = candidates;
    }

    available.sort(_compareCandidates);

    for (final candidate in available) {
      if (candidate != activeUrl) {
        _index = _urls.indexOf(candidate);
        if (_index == -1) _index = 0;
        _switches++;
        _protocolHint = ProtocolCache.get(candidate);
        debugPrint(
          '[MirrorFailover] advanced to mirror $_index: ${_urls[_index]} (proto: $_protocolHint)',
        );
        return candidate;
      }
    }

    if (_index + 1 >= _urls.length) return null;
    _index++;
    _switches++;
    _protocolHint = ProtocolCache.get(_urls[_index]);
    return _urls[_index];
  }

  void reportSlowMirror(String slowUrl, String fastUrl) {
    debugPrint(
      '[MirrorFailover] Slow mirror reported: $slowUrl -> Fast mirror: $fastUrl',
    );
    MirrorHealthStore.instance.recordFailure(slowUrl);
    final slowIdx = _urls.indexOf(slowUrl);
    final fastIdx = _urls.indexOf(fastUrl);
    if (fastIdx != -1 && _index == slowIdx) {
      _index = fastIdx;
      _switches++;
      _protocolHint = ProtocolCache.get(fastUrl);
    }
  }

  Future<String?> run(
    Future<void> Function(String url) action, {
    double measuredBytesPerSec = 0.0,
  }) async {
    final validUrls =
        _urls.where((u) => !MirrorHealthStore.instance.isBlacklisted(u)).toList();
    final candidateUrls = validUrls.isNotEmpty
        ? List<String>.from(validUrls)
        : List<String>.from(_urls);

    candidateUrls.sort(_compareCandidates);

    for (var i = 0; i < candidateUrls.length; i++) {
      final url = candidateUrls[i];
      if (i > 0) {
        _switches++;
      }

      final circuit = _circuits.putIfAbsent(
        url,
        () => CircuitBreaker(
          failureThreshold: 3,
          openTimeout: const Duration(minutes: 30),
        ),
      );
      if (!circuit.allowRequest()) {
        debugPrint('[MirrorFailover] circuit open for mirror $url, skipping');
        continue;
      }
      try {
        final isMultiMirror = candidateUrls.length > 1;
        final retries = isMultiMirror ? 0 : 2;
        await RetryEngine(
          maxRetries: retries,
          baseDelay: isMultiMirror ? Duration.zero : const Duration(seconds: 2),
          backoffMultiplier: 2.0,
          maxDelay: const Duration(seconds: 10),
        ).execute(
          () => action(url),
          onRetry: (error, attempt, delay) {
            debugPrint(
              '[MirrorFailover] mirror $url attempt $attempt failed ($error); retrying in ${delay.inMilliseconds}ms',
            );
          },
        );
        await MirrorHealthStore.instance.recordSuccess(url,
            speedBps: measuredBytesPerSec);
        await MirrorHealthStore.instance.recordSpeed(url, measuredBytesPerSec);
        circuit.recordSuccess();
        _index = _urls.indexOf(url);
        if (_index == -1) _index = 0;
        _protocolHint = ProtocolCache.get(url);
        return url;
      } catch (e) {
        await MirrorHealthStore.instance.recordFailure(url);
        circuit.recordFailure();
        if (e is DioException) {
          final status = e.response?.statusCode;
          if (status != null &&
              status >= 400 &&
              status < 500 &&
              status != 408 &&
              status != 429) {
            return null;
          }
        }
      }
    }
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Mirror Selector Unified Facade
// ═══════════════════════════════════════════════════════════════════════════

class MirrorSelector {
  final List<String> mirrorUrls;
  late final MirrorManager manager;
  late final MirrorParallelEngine parallelEngine;
  late final MirrorFailover failover;

  MirrorSelector(this.mirrorUrls) {
    manager = MirrorManager(mirrorUrls);
    failover = MirrorFailover(mirrorUrls);
    parallelEngine = MirrorParallelEngine(mirrorUrls, failover: failover);
  }
}
