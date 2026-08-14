import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/logging_service.dart';

void main() {
  group('LoggingService Tests (L-01 / L-02)', () {
    test('sanitize redacts sensitive credentials and tokens (L-01)', () {
      final msg =
          'Connecting with Bearer secret_token_12345 to https://api.com?api_key=my_super_secret_key';
      final sanitized = LoggingService.sanitize(msg);

      expect(sanitized, contains('Bearer [REDACTED]'));
      expect(sanitized, contains('api_key=[REDACTED]'));
      expect(sanitized, isNot(contains('secret_token_12345')));
      expect(sanitized, isNot(contains('my_super_secret_key')));
    });

    test('sanitize redacts Basic auth and URI embedded passwords (L-01)', () {
      final msg =
          'Request with Basic dXNlcjpwYXNz to http://admin:password123@proxy.lan:8080';
      final sanitized = LoggingService.sanitize(msg);

      expect(sanitized, contains('Basic [REDACTED]'));
      expect(sanitized, contains('://[REDACTED]:[REDACTED]@'));
      expect(sanitized, isNot(contains('password123')));
    });

    test('logger returns configured logger instance without throwing (L-02)',
        () {
      final logger = LoggingService.logger('TestLogger');
      expect(logger.name, equals('TestLogger'));
      logger.info('Test log entry');
    });
  });
}
