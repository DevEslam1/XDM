import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'mirror_health_store.dart';

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
      try {
        await action(url);
        await MirrorHealthStore.recordSuccess(url);
        _index = i; 
        return url;
      } catch (e) {
        await MirrorHealthStore.recordFailure(url);
        if (e is DioException) {
          final status = e.response?.statusCode;
          // Non-retryable HTTP errors
          if (status != null &&
              status >= 400 &&
              status < 500 &&
              status != 408 &&
              status != 429 &&
              status != 404 &&
              status != 403) {
            return null;
          }
        }
      }
    }
    return null;
  }
}