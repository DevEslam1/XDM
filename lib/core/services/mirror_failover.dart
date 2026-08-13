import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'circuit_breaker.dart';
import 'mirror_health_store.dart';
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

  /// ERR-RESILIENCE-2.2: Per-mirror circuit breaker. A mirror whose circuit
  /// opens is skipped on subsequent runs until its openTimeout (30 min) elapses.
  final Map<String, CircuitBreaker> _circuits = {};

  String get activeUrl => _urls.isEmpty ? '' : _urls[_index];
  bool get hasAlternatives => _urls.length > 1;
  int get remainingAlternatives => _urls.length - 1 - _index;
  int get mirrorSwitches => _switches;

  /// Records a successful download for the currently active mirror URL.
  Future<void> reportSuccess() async {
    if (_urls.isEmpty) return;
    await MirrorHealthStore.recordSuccess(_urls[_index]);
  }

  /// Advances to the next available mirror URL.
  ///
  /// Returns the new active URL, or `null` if all mirrors have been exhausted.
  String? advance() {
    if (_index + 1 >= _urls.length) return null;
    _index++;
    _switches++;
    debugPrint('[MirrorFailover] advanced to mirror $_index: ${_urls[_index]}');
    return _urls[_index];
  }

  Future<String?> run(Future<void> Function(String url) action) async {
    final validUrls =
        _urls.where((u) => !MirrorHealthStore.isBlacklisted(u)).toList();
    final candidateUrls = validUrls.isNotEmpty ? validUrls : _urls;

    for (var i = 0; i < candidateUrls.length; i++) {
      final url = candidateUrls[i];
      if (i > 0) {
        _switches++;
      }
      // ERR-RESILIENCE-2.2: Skip mirrors with an open circuit (recent
      // repeated failures). Open circuits expire after 30 minutes.
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
        // ERR-RESILIENCE-2.1: Per-mirror transient retry before advancing.
        // Non-transient HTTP errors (4xx except 408/429) skip retry and move
        // to the next mirror immediately.
        await RetryEngine(
          maxRetries: 2,
          baseDelay: const Duration(seconds: 2),
          backoffMultiplier: 2.0,
          maxDelay: const Duration(seconds: 10),
        ).execute(
          () => action(url),
          onRetry: (error, attempt, delay) {
            debugPrint(
                '[MirrorFailover] mirror $url attempt $attempt failed ($error); retrying in ${delay.inMilliseconds}ms');
          },
        );
        await MirrorHealthStore.recordSuccess(url);
        circuit.recordSuccess();
        _index = i;
        return url;
      } catch (e) {
        await MirrorHealthStore.recordFailure(url);
        circuit.recordFailure();
        if (e is DioException) {
          final status = e.response?.statusCode;
          // Non-retryable HTTP errors
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
