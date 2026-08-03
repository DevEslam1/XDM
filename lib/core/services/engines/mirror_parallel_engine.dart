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
    final threadsPerMirror = totalThreads ~/ _mirrorUrls.length;
    var remainder = totalThreads % _mirrorUrls.length;

    var threadIndex = 0;
    for (final mirror in _mirrorUrls) {
      final count = threadsPerMirror + (remainder > 0 ? 1 : 0);
      if (remainder > 0) remainder--;
      distribution[mirror] = List.generate(count, (_) => threadIndex++);
    }
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
    final fastest = _mirrorStates.entries
        .reduce((a, b) => a.value.averageSpeed > b.value.averageSpeed ? a : b);
    _log.info(
      '[MirrorParallel] Redistributing threads from slow mirror $slowMirror to ${fastest.key}',
    );
  }
}
