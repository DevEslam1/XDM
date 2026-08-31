import 'package:dmx/core/services/xdm_backend_client.dart';
import 'package:dmx/core/services/xdm_backend_exceptions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('clearing API key removes stored key', () async {
      await XdmBackendClient.setApiKey('');
      // Calling loadApiKey falls back to default key safely
      await XdmBackendClient.loadApiKey();
    });

    test('loadApiKey does not throw when storage is empty', () async {
      await XdmBackendClient.loadApiKey();
    });

    test('BackendException is properly typed', () {
      const authErr = BackendUnauthorizedException();
      expect(authErr, isA<BackendException>());
      expect(authErr.toUserMessage(), isNotEmpty);
      expect(authErr.message, isNotEmpty);

      const badReqErr = BackendBadRequestException();
      expect(badReqErr, isA<BackendException>());

      const notFoundErr = BackendNotFoundException();
      expect(notFoundErr, isA<BackendException>());

      const rateLimitErr = BackendRateLimitException(retryAfterSeconds: 30);
      expect(rateLimitErr, isA<BackendException>());
      expect(rateLimitErr.retryAfterSeconds, 30);

      const networkErr = BackendNetworkException();
      expect(networkErr, isA<BackendException>());

      const unknownErr = BackendUnknownException();
      expect(unknownErr, isA<BackendException>());
    });
  });
}
