import 'package:logging/logging.dart';

class _MirrorState {
  final List<double> _speeds = [];
  double get averageSpeed =>
      _speeds.isEmpty ? 0 : _speeds.reduce((a, b) => a + b) / _speeds.length;

  void updateSpeed(double speed) {
    _speeds.add(speed);
    if (_speeds.length > 10) _speeds.removeAt(0);
  }
}

class MirrorParallelEngine {
  static final _log = Logger('MirrorParallelEngine');
  final List<String> _mirrorUrls;
  final Map<String, _MirrorState> _mirrorStates = {};

  MirrorParallelEngine(this._mirrorUrls);

  List<String> get mirrorUrls => List.unmodifiable(_mirrorUrls);

  Map<String, List<int>> distributeThreads(int totalThreads) {
    if (_mirrorUrls.isEmpty || totalThreads <= 0) return {};

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
    // FIX: Mirrors with 0 assigned threads are intentionally excluded from
    // the map so downstream code never iterates over empty thread lists.
    return distribution;
  }

  void reportMirrorSpeed(String mirrorUrl, double bytesPerSecond) {
    final state = _mirrorStates.putIfAbsent(mirrorUrl, () => _MirrorState());
    state.updateSpeed(bytesPerSecond);

    if (_mirrorStates.length > 1) {
      final avgSpeed = _mirrorStates.values
              .map((s) => s.averageSpeed)
              .reduce((a, b) => a + b) /
          _mirrorStates.length;

      if (state.averageSpeed < avgSpeed * 0.33 && state.averageSpeed > 0) {
        _redistributeFromSlowMirror(mirrorUrl);
      }
    }
  }

  void _redistributeFromSlowMirror(String slowMirror) {
    final slowState = _mirrorStates[slowMirror];
    final fastest = _mirrorStates.entries
        .reduce((a, b) => a.value.averageSpeed > b.value.averageSpeed ? a : b);
    // FIX: Previously logged "Redistributing threads" but never actually
    // redistributed — this class is a pure planner with no thread ownership.
    // Actual failover is handled by MirrorFailover in the download engine.
    _log.info(
      '[MirrorParallel] Slow mirror detected: $slowMirror '
      '(avg ${((slowState?.averageSpeed ?? 0) / 1024).toStringAsFixed(0)} KB/s). '
      'Fastest mirror: ${fastest.key} '
      '(avg ${(fastest.value.averageSpeed / 1024).toStringAsFixed(0)} KB/s). '
      'Failover is handled by the download engine via MirrorFailover.',
    );
  }
}
