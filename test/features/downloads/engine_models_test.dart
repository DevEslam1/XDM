import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadProgress Hardening (Sprint 2)', () {
    test('DownloadProgress equality uses chunkFingerprint and primary fields',
        () {
      const p1 = DownloadProgress(
        downloadedBytes: 1000,
        fileSize: 2000,
        speed: 150.4,
        eta: 10,
        chunkFingerprint: 42,
      );

      const p2 = DownloadProgress(
        downloadedBytes: 1000,
        fileSize: 2000,
        speed: 150.1, // rounds to same
        eta: 99, // not in equality
        chunkFingerprint: 42,
      );

      expect(p1 == p2, isTrue);
      expect(p1.hashCode == p2.hashCode, isTrue);

      const p3 = DownloadProgress(
        downloadedBytes: 1000,
        fileSize: 2000,
        speed: 150.4,
        eta: 10,
        chunkFingerprint: 999, // different fingerprint
      );
      expect(p1 == p3, isFalse);
    });

    test('DownloadProgress.fromWorkerMap reads chunkFingerprint', () {
      final p = DownloadProgress.fromWorkerMap(const {
        'downloadedBytes': 500,
        'fileSize': 1000,
        'speed': 50.0,
        'chunkFingerprint': 12345,
      });
      expect(p.chunkFingerprint, equals(12345));
    });
  });
}
