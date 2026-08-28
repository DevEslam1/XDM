import 'dart:math';
import 'protocol_cache.dart';

/// Short-term memory of protocol failures and learned host concurrency caps.
class ProtocolFallbackMemory {
  static final Map<String, DateTime> _h3Failures = {};
  static final Map<String, int> _hostConcurrencyCaps = {};
  static const _cooldown = Duration(minutes: 30);

  static void recordFailure(String url, ProtocolSupport support) {
    if (support != ProtocolSupport.http3) return;
    final host = _extractHost(url);
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
    final host = _extractHost(url);
    if (host == null) return false;
    final at = _h3Failures[host];
    return at != null && DateTime.now().difference(at) < _cooldown;
  }

  /// Records a learned concurrency cap for a host (e.g., when rate-limited or degraded).
  static void recordHostConcurrencyCap(String urlOrHost, int cap) {
    final host = _extractHost(urlOrHost);
    if (host == null) return;
    final clampedCap = max(1, cap);
    _hostConcurrencyCaps[host] = clampedCap;
    if (_hostConcurrencyCaps.length > 200) {
      _hostConcurrencyCaps.remove(_hostConcurrencyCaps.keys.first);
    }
  }

  /// Retrieves any learned concurrency cap for a host, or null if unconstrained.
  static int? getHostConcurrencyCap(String urlOrHost) {
    final host = _extractHost(urlOrHost);
    if (host == null) return null;
    return _hostConcurrencyCaps[host];
  }

  static void clearConcurrencyCaps() {
    _hostConcurrencyCaps.clear();
  }

  static String? _extractHost(String urlOrHost) {
    if (!urlOrHost.contains('://')) {
      final idx = urlOrHost.indexOf('/');
      return (idx != -1 ? urlOrHost.substring(0, idx) : urlOrHost)
          .toLowerCase()
          .trim();
    }
    return Uri.tryParse(urlOrHost)?.host.toLowerCase().trim();
  }
}
