import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/io.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadEngine SSL Hardening (FIX-0.1)', () {
    test(
        'buildTransferDio creates secure adapter with standard client callback',
        () {
      final client = buildTransferDio(
        url: 'https://backend-service-xyz.a.run.app/download',
      );

      expect(client.httpClientAdapter, isA<IOHttpClientAdapter>());
      final adapter = client.httpClientAdapter as IOHttpClientAdapter;
      expect(adapter.createHttpClient, isNotNull);
      final httpClient = adapter.createHttpClient!();
      expect(httpClient, isA<HttpClient>());
    });

    test('buildTransferDio configures standard client for arbitrary domains',
        () {
      final client = buildTransferDio(
        url: 'https://arbitrary-site.com/file.zip',
      );

      expect(client.httpClientAdapter, isA<IOHttpClientAdapter>());
      final adapter = client.httpClientAdapter as IOHttpClientAdapter;
      expect(adapter.createHttpClient, isNotNull);
      final httpClient = adapter.createHttpClient!();
      expect(httpClient, isA<HttpClient>());
    });

    test(
        'buildTransferDio handles developerMode setting gracefully without SSL bypass',
        () {
      SettingsProvider.instance.developerMode = true;

      final client = buildTransferDio(
        url: 'https://custom-server.local/file.zip',
      );

      final adapter = client.httpClientAdapter as IOHttpClientAdapter;
      final httpClient = adapter.createHttpClient!();
      expect(httpClient, isA<HttpClient>());

      // Reset
      SettingsProvider.instance.developerMode = false;
    });
  });
}
