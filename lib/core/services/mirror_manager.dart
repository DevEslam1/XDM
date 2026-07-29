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
    try {
      return _mirrors.firstWhere((m) => m.url == url);
    } catch (_) {
      return null;
    }
  }
}

class MirrorStats {
  final String url;
  int totalBytes = 0;
  int totalMs = 0;
  int failures = 0;
  DateTime? lastUsed;

  MirrorStats(this.url);

  double get avgSpeedBps => totalMs > 0 ? totalBytes / totalMs * 1000 : 0;
}
