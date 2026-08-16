import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadProgress.ytCombinedProgress', () {
    test('returns null when ytStreamKind is null', () {
      const progress = DownloadProgress(
        downloadedBytes: 100,
        fileSize: 1000,
        speed: 10.0,
        eta: 90,
      );
      expect(progress.ytCombinedProgress, isNull);
    });

    test('returns null when ytCounterpartSize is null or negative', () {
      const progress1 = DownloadProgress(
        downloadedBytes: 100,
        fileSize: 1000,
        speed: 10.0,
        eta: 90,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: null,
      );
      expect(progress1.ytCombinedProgress, isNull);

      const progress2 = DownloadProgress(
        downloadedBytes: 100,
        fileSize: 1000,
        speed: 10.0,
        eta: 90,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: -1,
      );
      expect(progress2.ytCombinedProgress, isNull);
    });

    test('returns null when total size is 0 to avoid division by zero', () {
      const progress = DownloadProgress(
        downloadedBytes: 0,
        fileSize: 0,
        speed: 0.0,
        eta: null,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 0,
      );
      expect(progress.ytCombinedProgress, isNull);
    });

    test('calculates combined progress accurately for video + audio', () {
      const progress = DownloadProgress(
        downloadedBytes: 500,
        fileSize: 1000,
        speed: 50.0,
        eta: 10,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 1000,
        ytDownloadedBytes: 500,
        ytCounterpartDownloadedBytes: 500,
      );
      expect(progress.ytCombinedProgress, closeTo(0.5, 0.001));
    });

    test('clamps combined progress between 0.0 and 1.0', () {
      const progressOverflow = DownloadProgress(
        downloadedBytes: 1200,
        fileSize: 1000,
        speed: 50.0,
        eta: 0,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 1000,
        ytDownloadedBytes: 1200,
        ytCounterpartDownloadedBytes: 1200,
      );
      expect(progressOverflow.ytCombinedProgress, equals(1.0));
    });
  });
}
