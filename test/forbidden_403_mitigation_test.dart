import 'package:dio/dio.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('403 Forbidden Risk Mitigation Tests', () {
    test(
        'fileNameFromContentDisposition decodes extended UTF-8 headers on GET fallback',
        () {
      final headers = Headers.fromMap({
        'content-disposition': ["filename*=UTF-8''my_test_video%201080p.mp4"],
      });
      final name = fileNameFromContentDisposition(headers);
      expect(name, equals('my_test_video 1080p.mp4'));
    });
  });
}
