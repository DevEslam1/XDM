import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/engines/speed_predictor.dart';

void main() {
  group('SpeedPredictor', () {
    test('constant speed predicts accurate speed and ETA', () {
      final predictor = SpeedPredictor();
      for (var i = 0; i < 10; i++) {
        predictor.addSample(1000000); // 1 MB/s
      }

      expect(predictor.predictedSpeed, closeTo(1000000, 1.0));
      expect(predictor.predictEta(10000000), equals(10)); // 10MB / 1MB/s = 10s
    });

    test('declining speed calculates negative trend', () {
      final predictor = SpeedPredictor();
      predictor.addSample(2000000);
      predictor.addSample(1800000);
      predictor.addSample(1500000);
      predictor.addSample(1200000);
      predictor.addSample(1000000);

      expect(predictor.speedTrend, lessThan(0));
    });

    test('reset clears sample history', () {
      final predictor = SpeedPredictor();
      predictor.addSample(1000000);
      predictor.reset();

      expect(predictor.predictedSpeed, equals(0));
      expect(predictor.predictEta(1000), equals(-1));
    });
  });
}
