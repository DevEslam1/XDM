import 'package:dio/dio.dart';
import 'mirror_health_store.dart';

List<String> orderMirrorUrls(List<String> urls, {String? primary}) {
  final list = List<String>.from(urls.where((u) => u.startsWith('http')));
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

/// Task-level mirror rotation. The engine advances to the next mirror only
/// after [failureThreshold] consecutive chunk-level failures on the current
/// URL, then resets per-chunk attempt counters so a bad mirror doesn't burn
/// every retry budget.
class MirrorFailover {
  MirrorFailover(List<String> urls)
      : _urls = List<String>.unmodifiable(
          urls.where((u) => u.startsWith('http')).toList(),
        );

  final List<String> _urls;
  int _index = 0;
  int _consecutiveErrors = 0;
  int _switches = 0;

  static const int failureThreshold = 2;

  String get activeUrl => _urls.isEmpty ? '' : _urls[_index];
  bool get hasAlternatives => _urls.length > 1;
  int get remainingAlternatives => _urls.length - 1 - _index;
  int get mirrorSwitches => _switches;

  void reportSuccess() => _consecutiveErrors = 0;

  void reportFailure() => _consecutiveErrors++;

  bool get shouldFailover =>
      _consecutiveErrors >= failureThreshold && _index < _urls.length - 1;

  /// Moves to the next mirror. Returns the new URL, or null when exhausted.
  String? advance() {
    if (_index >= _urls.length - 1) return null;
    _index++;
    _switches++;
    _consecutiveErrors = 0;
    return _urls[_index];
  }

  Future<String?> run(Future<void> Function(String url) action) async {
    final validUrls = _urls.where((u) => !MirrorHealthStore.isBlacklisted(u)).toList();
    final candidateUrls = validUrls.isNotEmpty ? validUrls : _urls;
    
    for (final url in candidateUrls) {
      if (url != candidateUrls.first) {
        _switches++;
      }
      try {
        await action(url);
        await MirrorHealthStore.recordSuccess(url);
        return url;
      } catch (e) {
        await MirrorHealthStore.recordFailure(url);
        if (e is DioException) {
          final status = e.response?.statusCode;
          if (status != null && status >= 400 && status < 500 && status != 408 && status != 429) {
            return null;
          }
        }
      }
    }
    return null;
  }
}
