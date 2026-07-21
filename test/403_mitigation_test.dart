import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('403 Forbidden Risk Mitigation Tests', () {
    test('fileNameFromContentDisposition decodes extended UTF-8 headers on GET fallback', () {
      final headers = Headers.fromMap({
        'content-disposition': ["filename*=UTF-8''my_test_video%201080p.mp4"],
      });
      final name = fileNameFromContentDisposition(headers);
      expect(name, equals('my_test_video 1080p.mp4'));
    });

    test('resolveMetadata handles standard HTTP URL resolution safely', () async {
      final engine = DownloadEngine();
      final meta = await engine.resolveMetadata(url: 'https://httpbin.org/bytes/1024');
      expect(meta.fileName, isNotEmpty);
    });
  });
}
