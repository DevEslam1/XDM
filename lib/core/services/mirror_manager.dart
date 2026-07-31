import 'package:logging/logging.dart';

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

  /// FIX(22): precision is computed in doubles, so the reported loss is only
  /// theoretically possible beyond ~2^53 bytes (>9 PB) — negligible in
  /// practice. The clamp below just guards against absurd outliers (e.g. from
  /// a corrupted byte counter) dominating mirror ranking.
  static const double _maxAvgSpeedBps = 10 * 1024 * 1024 * 1024; // 10 GiB/s

  double get avgSpeedBps {
    if (totalMs <= 0) return 0;
    final raw = totalBytes / totalMs * 1000;
    return raw > _maxAvgSpeedBps ? _maxAvgSpeedBps : raw;
  }
}
