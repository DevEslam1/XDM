import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/error_taxonomy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ErrorTaxonomy Unit Tests', () {
    test('classifies Auth errors (HTTP 401 & 403)', () {
      final res401 = ErrorTaxonomy.classify(Object(), httpStatus: 401);
      expect(res401.family, equals(ErrorFamily.auth));
      expect(res401.severe, isTrue);

      final res403 = ErrorTaxonomy.classify(Object(), httpStatus: 403);
      expect(res403.family, equals(ErrorFamily.auth));
    });

    test('classifies Server errors (HTTP 500, 503, 429)', () {
      final res500 = ErrorTaxonomy.classify(Object(), httpStatus: 500);
      expect(res500.family, equals(ErrorFamily.server));
      expect(res500.isServerError, isTrue);
      expect(res500.retryable, isTrue);

      final res429 = ErrorTaxonomy.classify(Object(), httpStatus: 429);
      expect(res429.family, equals(ErrorFamily.server));
    });

    test('classifies TimeoutException and Dio connection timeouts', () {
      final timeoutRes = ErrorTaxonomy.classify(TimeoutException('timeout'));
      expect(timeoutRes.family, equals(ErrorFamily.timeout));
      expect(timeoutRes.retryable, isTrue);

      final dioTimeout = ErrorTaxonomy.classify(
        DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.connectionTimeout,
        ),
      );
      expect(dioTimeout.family, equals(ErrorFamily.timeout));
    });

    test('classifies SocketException and Dio connection errors', () {
      final socketRes = ErrorTaxonomy.classify(const SocketException('No route to host'));
      expect(socketRes.family, equals(ErrorFamily.network));
      expect(socketRes.isNetworkError, isTrue);
      expect(socketRes.retryable, isTrue);
    });

    test('classifies FileSystemException disk full', () {
      final diskFull = ErrorTaxonomy.classify(
        const FileSystemException('No space left on device'),
      );
      expect(diskFull.family, equals(ErrorFamily.disk));
      expect(diskFull.message, equals('Storage full'));
      expect(diskFull.severe, isTrue);
    });

    test('classifies cancelled requests', () {
      final cancel = ErrorTaxonomy.classify(
        DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.cancel,
        ),
      );
      expect(cancel.family, equals(ErrorFamily.cancelled));
      expect(cancel.retryable, isFalse);
    });
  });
}
