import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/browser/services/download_interceptor.dart';

void main() {
  group('DownloadInterceptor status enum', () {
    test('InterceptDownloadStatus values exist', () {
      expect(InterceptDownloadStatus.values, contains(InterceptDownloadStatus.alreadyCompleted));
      expect(InterceptDownloadStatus.values, contains(InterceptDownloadStatus.alreadyInProgress));
      expect(InterceptDownloadStatus.values, contains(InterceptDownloadStatus.resumed));
      expect(InterceptDownloadStatus.values, contains(InterceptDownloadStatus.queued));
      expect(InterceptDownloadStatus.values, contains(InterceptDownloadStatus.failed));
      expect(InterceptDownloadStatus.values, contains(InterceptDownloadStatus.skipped));
    });

    test('InterceptDownloadResult contains status and message', () {
      const result = InterceptDownloadResult(InterceptDownloadStatus.failed, 'Network error');
      expect(result.status, equals(InterceptDownloadStatus.failed));
      expect(result.errorMessage, equals('Network error'));
    });
  });

  group('DownloadInterceptor bypass set', () {
    test('consumeBypass returns true once for bypassed URL', () {
      final interceptor = DownloadInterceptor(
        resolveDownloadProvider: () => throw UnimplementedError(),
        resolveActiveTab: () => null,
      );

      interceptor.addBypass('https://example.com/video.mp4');
      expect(interceptor.consumeBypass('https://example.com/video.mp4'), isTrue);
      expect(interceptor.consumeBypass('https://example.com/video.mp4'), isFalse);
    });

    test('consumeBypass returns true for bypassed URL and false afterwards', () {
      final interceptor = DownloadInterceptor(
        resolveDownloadProvider: () => throw UnimplementedError(),
        resolveActiveTab: () => null,
      );

      interceptor.addBypass('https://example.com/file.zip');
      expect(interceptor.consumeBypass('https://example.com/file.zip'), isTrue);
      expect(interceptor.consumeBypass('https://example.com/file.zip'), isFalse);
    });
  });
}
