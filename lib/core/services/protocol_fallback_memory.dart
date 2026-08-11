import 'protocol_cache.dart';

/// Short-term memory of protocol failures so we don't retry a dead h3 path.
class ProtocolFallbackMemory {
  static final Map<String, DateTime> _h3Failures = {};
  static const _cooldown = Duration(minutes: 30);

  static void recordFailure(String url, ProtocolSupport support) {
    if (support != ProtocolSupport.http3) return;
    final host = Uri.tryParse(url)?.host;
    if (host != null) {
      final now = DateTime.now();
      _h3Failures[host] = now;
      if (_h3Failures.length > 200) {
        _h3Failures.removeWhere((_, at) => now.difference(at) >= _cooldown);
        if (_h3Failures.length > 200) {
          _h3Failures.remove(_h3Failures.keys.first);
        }
      }
    }
  }

  static bool recentlyFailed(String url, ProtocolSupport support) {
    if (support != ProtocolSupport.http3) return false;
    final host = Uri.tryParse(url)?.host;
    if (host == null) return false;
    final at = _h3Failures[host];
    return at != null && DateTime.now().difference(at) < _cooldown;
  }
}
