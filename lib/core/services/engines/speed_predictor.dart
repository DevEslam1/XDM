import 'dart:math';

class _SpeedSample {
  final double speed;
  final int timestamp;
  const _SpeedSample({required this.speed, required this.timestamp});
}

/// Predicts download completion time using exponential moving average (EMA α=0.3).
class SpeedPredictor {
  final List<_SpeedSample> _samples = [];
  static const _maxSamples = 30;

  void addSample(double bytesPerSecond) {
    _samples.add(_SpeedSample(
      speed: bytesPerSecond,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));
    if (_samples.length > _maxSamples) _samples.removeAt(0);
  }

  double get predictedSpeed {
    if (_samples.isEmpty) return 0;
    if (_samples.length == 1) return _samples.first.speed;

    double ema = _samples.first.speed;
    for (var i = 1; i < _samples.length; i++) {
      ema = 0.3 * _samples[i].speed + 0.7 * ema;
    }
    return ema;
  }

  int predictEta(int remainingBytes) {
    final speed = predictedSpeed;
    if (speed <= 0 || remainingBytes <= 0) return -1;
    return (remainingBytes / speed).ceil();
  }

  double get speedTrend {
    if (_samples.length < 5) return 0;
    final recent = _samples.sublist(_samples.length - 5);
    final first = recent.first.speed;
    final last = recent.last.speed;
    return first > 0 ? (last - first) / first : 0;
  }

  double get confidence {
    if (_samples.length < 3) return 0.2;
    if (_samples.length < 10) return 0.5;

    final speeds = _samples.map((s) => s.speed).toList();
    final mean = speeds.reduce((a, b) => a + b) / speeds.length;
    if (mean <= 0) return 0.2;

    final variance =
        speeds.map((s) => (s - mean) * (s - mean)).reduce((a, b) => a + b) /
            speeds.length;
    final cv = sqrt(variance) / mean;

    return (1.0 - cv.clamp(0.0, 1.0)) *
        (_samples.length / _maxSamples).clamp(0.0, 1.0);
  }

  void reset() => _samples.clear();
}
