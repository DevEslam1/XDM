import 'dart:math' show max;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'circuit_breaker.dart';
import 'mirror_health_store.dart';
import 'protocol_cache.dart';
import 'retry_engine.dart';

List<String> orderMirrorUrls(List<String> urls, {String? primary}) {
  final list = List<String>.from(
      urls.where((u) => u.startsWith('http://') || u.startsWith('https://')));
  list.sort((a, b) {
    if (a == primary) return -1;
    if (b == primary) return 1;
    final blackA = MirrorHealthStore.isBlacklisted(a);
    final blackB = MirrorHealthStore.isBlacklisted(b);
    if (blackA != blackB) return blackA ? 1 : -1;
    final speedA = MirrorHealthStore.getPersistedSpeed(a);
    final speedB = MirrorHealthStore.getPersistedSpeed(b);
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

  /// ERR-RESILIENCE-2.2: Per-mirror circuit breaker. A mirror whose circuit
  /// opens is skipped on subsequent runs until its openTimeout (30 min) elapses.
  final Map<String, CircuitBreaker> _circuits = {};

  String get activeUrl => _urls.isEmpty ? '' : _urls[_index];
  bool get hasAlternatives => _urls.length > 1;
  int get remainingAlternatives => _urls.length - 1 - _index;
  int get mirrorSwitches => _switches;
  ProtocolSupport? get protocolHint => _protocolHint;

  int _compareCandidates(String urlA, String urlB) {
    final speedA = MirrorHealthStore.getPersistedSpeed(urlA);
    final speedB = MirrorHealthStore.getPersistedSpeed(urlB);

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

  /// Records a successful download for the currently active mirror URL.
  Future<void> reportSuccess({double speedBps = 0.0}) async {
    if (_urls.isEmpty) return;
    await MirrorHealthStore.recordSuccess(_urls[_index], speedBps: speedBps);
  }

  /// Advances to the next available mirror URL, respecting circuit state and speed/protocol ranking.
  String? advance() {
    if (_urls.isEmpty) return null;

    final validUrls =
        _urls.where((u) => !MirrorHealthStore.isBlacklisted(u)).toList();
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
    MirrorHealthStore.recordFailure(slowUrl);
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
        _urls.where((u) => !MirrorHealthStore.isBlacklisted(u)).toList();
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
        await RetryEngine(
          maxRetries: 2,
          baseDelay: const Duration(seconds: 2),
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
        await MirrorHealthStore.recordSuccess(url,
            speedBps: measuredBytesPerSec);
        await MirrorHealthStore.recordSpeed(url, measuredBytesPerSec);
        circuit.recordSuccess();
        _index = _urls.indexOf(url);
        if (_index == -1) _index = 0;
        _protocolHint = ProtocolCache.get(url);
        return url;
      } catch (e) {
        await MirrorHealthStore.recordFailure(url);
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
