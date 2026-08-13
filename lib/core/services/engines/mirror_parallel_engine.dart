import 'dart:collection';
import 'package:logging/logging.dart';
import '../mirror_failover.dart';

class _MirrorState {
  final Queue<double> _speeds = Queue<double>();
  double get averageSpeed =>
      _speeds.isEmpty ? 0 : _speeds.reduce((a, b) => a + b) / _speeds.length;

  void updateSpeed(double speed) {
    _speeds.add(speed);
    if (_speeds.length > 10) _speeds.removeFirst();
  }
}

class MirrorParallelEngine {
  static final _log = Logger('MirrorParallelEngine');
  final List<String> _mirrorUrls;
  final Map<String, _MirrorState> _mirrorStates = {};
  MirrorFailover? failover;

  MirrorParallelEngine(this._mirrorUrls, {this.failover});

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

    // Check if any mirror is slow (< 33% of average speed) and reallocate its threads to the fastest mirror
    if (_mirrorStates.length > 1) {
      final avgSpeed = _mirrorStates.values
              .map((s) => s.averageSpeed)
              .reduce((a, b) => a + b) /
          _mirrorStates.length;

      if (avgSpeed > 0) {
        final slowMirrors = distribution.keys.where((m) {
          final s = _mirrorStates[m];
          return s != null &&
              s.averageSpeed > 0 &&
              s.averageSpeed < avgSpeed * 0.33;
        }).toList();

        if (slowMirrors.isNotEmpty) {
          final fastestEntry = _mirrorStates.entries.reduce(
              (a, b) => a.value.averageSpeed > b.value.averageSpeed ? a : b);
          final fastestMirror = fastestEntry.key;

          for (final slowMirror in slowMirrors) {
            if (slowMirror != fastestMirror &&
                distribution.containsKey(slowMirror)) {
              final threadsToReallocate = distribution.remove(slowMirror) ?? [];
              if (threadsToReallocate.isNotEmpty) {
                distribution.putIfAbsent(fastestMirror, () => []);
                distribution[fastestMirror]!.addAll(threadsToReallocate);
                _log.info(
                  '[MirrorParallel] Reallocated ${threadsToReallocate.length} threads from slow mirror $slowMirror to fastest $fastestMirror',
                );
                failover?.reportSlowMirror(slowMirror, fastestMirror);
              }
            }
          }
        }
      }
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
        _logSlowMirrorDetected(mirrorUrl);
      }
    }
  }

  void _logSlowMirrorDetected(String slowMirror) {
    final slowState = _mirrorStates[slowMirror];
    final fastest = _mirrorStates.entries
        .reduce((a, b) => a.value.averageSpeed > b.value.averageSpeed ? a : b);
    _log.info(
      '[MirrorParallel] Slow mirror detected: $slowMirror '
      '(avg ${((slowState?.averageSpeed ?? 0) / 1024).toStringAsFixed(0)} KB/s). '
      'Reallocating threads to fastest mirror: ${fastest.key} '
      '(avg ${(fastest.value.averageSpeed / 1024).toStringAsFixed(0)} KB/s).',
    );
    failover?.reportSlowMirror(slowMirror, fastest.key);
  }
}
