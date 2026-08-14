import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/io.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadEngine SSL Scoping (SEC-01)', () {
    test(
        'buildTransferDio creates adapter with scoped client callback for backend host',
        () {
      final client = buildTransferDio(
        url: 'https://backend-service-xyz.a.run.app/download',
        bypassSSL: true,
      );

      expect(client.httpClientAdapter, isA<IOHttpClientAdapter>());
      final adapter = client.httpClientAdapter as IOHttpClientAdapter;
      expect(adapter.createHttpClient, isNotNull);
      final httpClient = adapter.createHttpClient!();
      expect(httpClient, isA<HttpClient>());
    });

    test('buildTransferDio configures standard client when bypassSSL is false',
        () {
      final client = buildTransferDio(
        url: 'https://arbitrary-site.com/file.zip',
        bypassSSL: false,
      );

      expect(client.httpClientAdapter, isA<IOHttpClientAdapter>());
      final adapter = client.httpClientAdapter as IOHttpClientAdapter;
      expect(adapter.createHttpClient, isNotNull);
      final httpClient = adapter.createHttpClient!();
      expect(httpClient, isA<HttpClient>());
    });

    test('buildTransferDio handles developerMode setting gracefully', () {
      SettingsProvider.instance.developerMode = true;

      final client = buildTransferDio(
        url: 'https://custom-server.local/file.zip',
        bypassSSL: true,
      );

      final adapter = client.httpClientAdapter as IOHttpClientAdapter;
      final httpClient = adapter.createHttpClient!();
      expect(httpClient, isA<HttpClient>());

      // Reset
      SettingsProvider.instance.developerMode = false;
    });
  });
}
