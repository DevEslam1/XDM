import 'package:dmx/core/services/xdm_backend_exceptions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BackendException hierarchy', () {
    test('BackendBadRequestException has a default message', () {
      const e = BackendBadRequestException();
      expect(e.message, 'Invalid URL or unsupported video.');
      expect(e.toUserMessage(), e.message);
      expect(e, isA<BackendException>());
    });

    test('BackendBadRequestException accepts a custom message', () {
      const e = BackendBadRequestException('custom bad request');
      expect(e.message, 'custom bad request');
      expect(e.toString(), 'BackendBadRequestException: custom bad request');
    });

    test('BackendUnauthorizedException defaults and overrides', () {
      const e = BackendUnauthorizedException();
      expect(e.message, 'Backend authentication failed. Check your API token.');
      expect(e.toUserMessage(), e.message);
      const custom = BackendUnauthorizedException('nope');
      expect(custom.message, 'nope');
    });

    test('BackendNotFoundException defaults and overrides', () {
      const e = BackendNotFoundException();
      expect(e.message, 'No streams found for this video.');
      expect(e.toUserMessage(), e.message);
      const custom = BackendNotFoundException('missing');
      expect(custom.message, 'missing');
    });

    test('BackendRateLimitException derives message from retryAfterSeconds', () {
      const e = BackendRateLimitException(retryAfterSeconds: 42);
      expect(e.retryAfterSeconds, 42);
      expect(e.message, contains('42 seconds'));
      expect(e.toUserMessage(), e.message);
    });

    test('BackendRateLimitException without retry uses generic default', () {
      const e = BackendRateLimitException();
      expect(e.retryAfterSeconds, isNull);
      expect(e.message, 'Rate limit reached. Try again later.');
    });

    test('BackendRateLimitException honours an explicit message', () {
      const e = BackendRateLimitException(
        retryAfterSeconds: 10,
        message: 'slow down',
      );
      expect(e.message, 'slow down');
      expect(e.retryAfterSeconds, 10);
    });

    test('BackendNetworkException defaults and overrides', () {
      const e = BackendNetworkException();
      expect(e.message, 'Cannot reach download backend. Check your connection.');
      expect(e.toUserMessage(), e.message);
      const custom = BackendNetworkException('offline');
      expect(custom.message, 'offline');
    });

    test('BackendUnknownException defaults and overrides', () {
      const e = BackendUnknownException();
      expect(e.message, 'Unexpected backend error.');
      expect(e.toUserMessage(), e.message);
      const custom = BackendUnknownException('???');
      expect(custom.message, '???');
    });

    test('XdmBackendTimeoutException defaults and overrides', () {
      const e = XdmBackendTimeoutException();
      expect(e.message, 'The backend request timed out.');
      expect(e, isA<BackendException>());
      const custom = XdmBackendTimeoutException('took too long');
      expect(custom.message, 'took too long');
    });

    test('BackendTimeoutException typedef aliases XdmBackendTimeoutException',
        () {
      const BackendTimeoutException e = XdmBackendTimeoutException('alias');
      expect(e, isA<XdmBackendTimeoutException>());
      expect(e.message, 'alias');
    });

    test('sealed hierarchy can be switched exhaustively', () {
      String describe(BackendException e) => switch (e) {
            BackendBadRequestException() => 'bad-request',
            BackendUnauthorizedException() => 'unauthorized',
            BackendNotFoundException() => 'not-found',
            BackendRateLimitException() => 'rate-limit',
            BackendNetworkException() => 'network',
            BackendUnknownException() => 'unknown',
            XdmBackendTimeoutException() => 'timeout',
          };
      expect(describe(const BackendBadRequestException()), 'bad-request');
      expect(describe(const BackendUnauthorizedException()), 'unauthorized');
      expect(describe(const BackendNotFoundException()), 'not-found');
      expect(describe(const BackendRateLimitException()), 'rate-limit');
      expect(describe(const BackendNetworkException()), 'network');
      expect(describe(const BackendUnknownException()), 'unknown');
      expect(describe(const XdmBackendTimeoutException()), 'timeout');
    });
  });
}
