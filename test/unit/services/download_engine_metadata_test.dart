import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/download_engine.dart';

void main() {
  group('DownloadEngine Metadata Parallel Probe Tests (E-03)', () {
    test('DownloadMetadata.isValid reflects fileSize > 0', () {
      final valid = DownloadMetadata(
        fileName: 'test.zip',
        category: 'Archive',
        fileSize: 1024,
        supportsResume: true,
      );
      expect(valid.isValid, isTrue);

      final invalid = DownloadMetadata(
        fileName: 'unknown',
        category: 'Other',
        fileSize: 0,
        supportsResume: false,
      );
      expect(invalid.isValid, isFalse);
    });
  });
}
