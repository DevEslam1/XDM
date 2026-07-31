import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/xdm_backend_client.dart';
import 'package:dmx/core/services/xdm_backend_exceptions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('XdmBackendClient', () {
    setUp(() async {
      // Set mock for flutter_secure_storage to avoid MissingPluginException
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (methodCall) async => null,
      );
    });

    test('throws BackendUnauthorizedException when no key is configured', () {
      expect(
        () => XdmBackendClient().health(),
        throwsA(isA<BackendUnauthorizedException>()),
      );
    });

    test('throws BackendUnauthorizedException when key is empty string', () {
      XdmBackendClient.setApiKey('');
      expect(
        () => XdmBackendClient().health(),
        throwsA(isA<BackendUnauthorizedException>()),
      );
    });

    test('loadApiKey does not throw when storage is empty', () async {
      await XdmBackendClient.loadApiKey();
    });

    test('BackendException is properly typed', () {
      final authErr = const BackendUnauthorizedException();
      expect(authErr, isA<BackendException>());
      expect(authErr.toUserMessage(), isNotEmpty);
      expect(authErr.message, isNotEmpty);

      final badReqErr = const BackendBadRequestException();
      expect(badReqErr, isA<BackendException>());

      final notFoundErr = const BackendNotFoundException();
      expect(notFoundErr, isA<BackendException>());

      final rateLimitErr = const BackendRateLimitException(retryAfterSeconds: 30);
      expect(rateLimitErr, isA<BackendException>());
      expect(rateLimitErr.retryAfterSeconds, 30);

      final networkErr = const BackendNetworkException();
      expect(networkErr, isA<BackendException>());

      final unknownErr = const BackendUnknownException();
      expect(unknownErr, isA<BackendException>());
    });
  });
}
