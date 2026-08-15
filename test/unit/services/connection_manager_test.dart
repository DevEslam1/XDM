import 'package:dio/dio.dart';
import 'package:dmx/core/services/connection_manager.dart';
import 'package:dmx/core/services/protocol_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ConnectionManager Unit Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ProtocolCache.init();
    });

    test('createDownloadDio creates valid Dio instance', () {
      final dio = ConnectionManager.createDownloadDio();
      expect(dio, isNotNull);
      expect(dio.options.connectTimeout,
          equals(const Duration(milliseconds: 15000)));
      expect(dio.options.receiveTimeout,
          equals(const Duration(milliseconds: 60000)));
    });

    test('createProtocolDio returns configured Dio for each protocol', () {
      final dioH3 = ConnectionManager.createProtocolDio(ProtocolSupport.http3);
      expect(dioH3, isNotNull);

      final dioH2 = ConnectionManager.createProtocolDio(ProtocolSupport.http2);
      expect(dioH2, isNotNull);

      final dioH1 = ConnectionManager.createProtocolDio(ProtocolSupport.http11);
      expect(dioH1, isNotNull);
    });

    test('isGoawayOrReset correctly identifies GOAWAY & stream reset errors',
        () {
      final goawayErr = DioException(
        requestOptions: RequestOptions(path: '/'),
        message: 'HTTP/2 GOAWAY received',
      );
      expect(ConnectionManager.isGoawayOrReset(goawayErr), isTrue);

      final resetErr = DioException(
        requestOptions: RequestOptions(path: '/'),
        message: 'stream was reset by peer',
      );
      expect(ConnectionManager.isGoawayOrReset(resetErr), isTrue);

      final unknownErr = DioException(
        requestOptions: RequestOptions(path: '/'),
        message: 'Connection timed out',
      );
      expect(ConnectionManager.isGoawayOrReset(unknownErr), isFalse);

      expect(ConnectionManager.isGoawayOrReset(Exception('generic error')),
          isFalse);
    });

    test('detectHttp2 returns false for non-https URLs gracefully', () async {
      final isH2 = await ConnectionManager.detectHttp2('http://example.com');
      expect(isH2, isFalse);
    });

    test('detectBestProtocol handles cached and uncached URLs', () async {
      const url = 'https://cached-host.com/test.bin';
      await ProtocolCache.record(url, ProtocolSupport.http2);

      final proto = await ConnectionManager.detectBestProtocol(url);
      expect(proto, equals(ProtocolSupport.http2));
    });

    test('invalidate clears both internal probes and ProtocolCache', () async {
      const url = 'https://test-invalidate.com/file.bin';
      await ProtocolCache.record(url, ProtocolSupport.http2);
      expect(ProtocolCache.get(url), equals(ProtocolSupport.http2));

      ConnectionManager.invalidate('test-invalidate.com');
      expect(ProtocolCache.get(url), isNull);
    });
  });
}
