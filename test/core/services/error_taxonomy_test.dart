import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ErrorTaxonomy', () {
    test('classifies DioException cancel correctly', () {
      final dioCancel = DioException(
        requestOptions: RequestOptions(path: 'https://example.com/file.zip'),
        type: DioExceptionType.cancel,
      );
      final result = ErrorTaxonomy.classify(dioCancel);
      expect(result.family, ErrorFamily.cancelled);
      expect(result.recoveryAction, RecoveryAction.ignore);
      expect(result.retryable, false);
    });

    test('classifies disk full / insufficient storage error correctly', () {
      const diskError = InsufficientStorageException();
      final result = ErrorTaxonomy.classify(diskError);
      expect(result.family, ErrorFamily.disk);
      expect(result.severe, true);
      expect(result.recoveryAction, RecoveryAction.showSettings);
    });

    test('classifies integrity error correctly', () {
      const integrityError = DownloadIntegrityException('Checksum mismatch');
      final result = ErrorTaxonomy.classify(integrityError);
      expect(result.family, ErrorFamily.integrity);
      expect(result.recoveryAction, RecoveryAction.restartDownload);
    });

    test('classifies socket exception as network error with delay', () {
      const socketError = SocketException('Failed host lookup');
      final result = ErrorTaxonomy.classify(socketError);
      expect(result.family, ErrorFamily.network);
      expect(result.retryable, true);
      expect(result.recoveryAction, RecoveryAction.retryWithDelay);
    });

    test('classifies 503 HTTP server error as retryable', () {
      final serverError = DioException(
        requestOptions: RequestOptions(path: 'https://example.com'),
        response: Response(
          requestOptions: RequestOptions(path: 'https://example.com'),
          statusCode: 503,
        ),
      );
      final result = ErrorTaxonomy.classify(serverError);
      expect(result.family, ErrorFamily.server);
      expect(result.httpStatus, 503);
      expect(result.retryable, true);
      expect(result.recoveryAction, RecoveryAction.retrySame);
    });

    test('classifies 410 Gone as auth/expired URL requiring refresh', () {
      final goneError = DioException(
        requestOptions: RequestOptions(path: 'https://example.com'),
        response: Response(
          requestOptions: RequestOptions(path: 'https://example.com'),
          statusCode: 410,
        ),
      );
      final result = ErrorTaxonomy.classify(goneError);
      expect(result.family, ErrorFamily.auth);
      expect(result.httpStatus, 410);
      expect(result.recoveryAction, RecoveryAction.refreshUrl);
    });
  });
}
