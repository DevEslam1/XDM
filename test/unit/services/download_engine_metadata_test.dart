import 'package:dmx/core/services/download_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadEngine Metadata Parallel Probe Tests (E-03)', () {
    test('DownloadMetadata.isValid reflects non-empty fileName', () {
      const valid = DownloadMetadata(
        fileName: 'test.zip',
        category: 'Archive',
        fileSize: 1024,
        supportsResume: true,
      );
      expect(valid.isValid, isTrue);

      const validZeroSize = DownloadMetadata(
        fileName: 'stream.mp4',
        category: 'video',
        fileSize: 0,
        supportsResume: false,
      );
      expect(validZeroSize.isValid, isTrue);

      const invalid = DownloadMetadata(
        fileName: '',
        category: 'Other',
        fileSize: 0,
        supportsResume: false,
      );
      expect(invalid.isValid, isFalse);
    });
  });
}
