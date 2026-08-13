import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:dmx/core/services/download_engine.dart';

void main() {
  group('ErrorTaxonomy.classify()', () {
    test('1. DioException cancel → ErrorFamily.cancelled', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.cancel,
      );
      final res = ErrorTaxonomy.classify(err);
      expect(res.family, equals(ErrorFamily.cancelled));
    });

    test('2. InsufficientStorageException → ErrorFamily.disk', () {
      final err = const InsufficientStorageException('Not enough space');
      final res = ErrorTaxonomy.classify(err);
      expect(res.family, equals(ErrorFamily.disk));
    });

    test('3. DownloadIntegrityException → ErrorFamily.integrity', () {
      final err = const DownloadIntegrityException('CRC mismatch');
      final res = ErrorTaxonomy.classify(err);
      expect(res.family, equals(ErrorFamily.integrity));
    });

    test('4. DioException 403 → ErrorFamily.auth', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/file'),
        response: Response(
          requestOptions: RequestOptions(path: '/file'),
          statusCode: 403,
        ),
      );
      final res = ErrorTaxonomy.classify(err);
      expect(res.family, equals(ErrorFamily.auth));
    });

    test('5. DioException 500 → ErrorFamily.server', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/file'),
        response: Response(
          requestOptions: RequestOptions(path: '/file'),
          statusCode: 500,
        ),
      );
      final res = ErrorTaxonomy.classify(err);
      expect(res.family, equals(ErrorFamily.server));
    });

    test('6. SocketException → ErrorFamily.network', () {
      const err = SocketException('Failed host lookup');
      final res = ErrorTaxonomy.classify(err);
      expect(res.family, equals(ErrorFamily.network));
    });

    test('7. TimeoutException → ErrorFamily.timeout', () {
      final err = TimeoutException('Connection timed out');
      final res = ErrorTaxonomy.classify(err);
      expect(res.family, equals(ErrorFamily.timeout));
    });

    test('8. Unknown error → ErrorFamily.unknown', () {
      final err = Exception('Random failure');
      final res = ErrorTaxonomy.classify(err);
      expect(res.family, equals(ErrorFamily.unknown));
    });

    test('9. recoveryAction maps families correctly', () {
      final cancelled = ErrorTaxonomy.classify(
        DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.cancel,
        ),
      );
      expect(cancelled.recoveryAction, equals(RecoveryAction.ignore));
    });
  });
}
