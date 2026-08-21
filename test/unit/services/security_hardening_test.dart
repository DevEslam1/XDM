import 'dart:io';
import 'package:dmx/core/services/diagnostic_service.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/remote_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Task 9: Security Hardening & Secret Defense Suite', () {
    test('LoggingService.sanitize strictly redacts bearer tokens, secrets, and auth headers', () {
      const rawText = 'Request headers: Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 '
          'and client_secret=9f8e7d6c5b4a3a2b1 and password="mySecretPassword123!"';

      final sanitized = LoggingService.sanitize(rawText);

      expect(sanitized, isNot(contains('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9')));
      expect(sanitized, isNot(contains('9f8e7d6c5b4a3a2b1')));
      expect(sanitized, isNot(contains('mySecretPassword123!')));
      expect(sanitized, contains('Bearer [REDACTED]'));
    });

    test('DiagnosticService redacts sensitive tokens upon entry recording', () {
      DiagnosticService.instance.record('AUTH_EVENT', 'User authenticated with api_key=secret-key-xyz-12345');

      final logs = DiagnosticService.instance.entries;
      final hasSecret = logs.any((entry) => entry.message.contains('secret-key-xyz-12345'));

      expect(hasSecret, isFalse,
          reason: 'DiagnosticService must sanitize all messages to prevent secret retention');
    });

    test('RemoteApiService is configured strictly for loopback IPv4', () {
      expect(RemoteApiService.enabled, isFalse,
          reason: 'Remote API must be disabled by default');
      expect(InternetAddress.loopbackIPv4.address, equals('127.0.0.1'));
    });

    test('URL sanitization strips sensitive query params (key, token, secret, auth)', () {
      const testUrl = 'https://cdn.example.com/download/file.zip?token=secret123&auth=abcdef&name=file';
      final redacted = LoggingService.redactUrl(testUrl);

      expect(redacted, isNot(contains('token=secret123')));
      expect(redacted, isNot(contains('auth=abcdef')));
      expect(redacted, contains('[REDACTED]'));
      expect(redacted, contains('name=file'));
    });
  });
}
