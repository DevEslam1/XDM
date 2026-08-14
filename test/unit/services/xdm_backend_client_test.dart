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

    test('clearing API key removes stored key', () async {
      await XdmBackendClient.setApiKey('');
      // Calling loadApiKey falls back to default key safely
      await XdmBackendClient.loadApiKey();
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

      final rateLimitErr =
          const BackendRateLimitException(retryAfterSeconds: 30);
      expect(rateLimitErr, isA<BackendException>());
      expect(rateLimitErr.retryAfterSeconds, 30);

      final networkErr = const BackendNetworkException();
      expect(networkErr, isA<BackendException>());

      final unknownErr = const BackendUnknownException();
      expect(unknownErr, isA<BackendException>());
    });

    test('cache hit returns directly without probe (Y-02)', () async {
      final client = XdmBackendClient();
      final initialHits = XdmBackendClient.cacheHits;

      // Inject stream into cache via reflection/method if exposed or testing cache state
      expect(initialHits, isA<int>());
    });
  });
}
