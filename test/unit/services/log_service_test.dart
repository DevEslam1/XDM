import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LoggingService', () {
    test('init is idempotent', () {
      LoggingService.init();
      LoggingService.init(); // should not throw
    });

    test('logger returns a named logger', () {
      final log = LoggingService.logger('test');
      expect(log.name, 'test');
    });

    test('sanitize redacts bearer tokens', () {
      final result = LoggingService.sanitize(
        'Authorization: Bearer my-secret-token-12345',
      );
      expect(result, contains('Bearer [REDACTED]'));
      expect(result, isNot(contains('my-secret-token-12345')));
    });

    test('sanitize redacts API keys in query params', () {
      final result = LoggingService.sanitize(
        'https://example.com/api?api_key=super-secret&foo=bar',
      );
      expect(result, contains('api_key=[REDACTED]'));
      expect(result, isNot(contains('super-secret')));
    });

    test('sanitize redacts passwords in URLs', () {
      final result = LoggingService.sanitize(
        'https://user:mysecretpass@example.com/resource',
      );
      expect(result, contains('://[REDACTED]:[REDACTED]@'));
      expect(result, isNot(contains('mysecretpass')));
    });

    test('sanitize does not modify safe messages', () {
      const message = 'Download completed successfully';
      expect(LoggingService.sanitize(message), message);
    });
  });
}
