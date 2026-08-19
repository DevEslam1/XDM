import 'dart:io';
import 'dart:typed_data';

import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// [X509Certificate] is an interface with no public constructor in this SDK,
/// so implement it with inert stubs. The bypass callback never inspects the
/// certificate, so the field values don't matter.
class _FakeX509Certificate implements X509Certificate {
  @override
  Uint8List get der => Uint8List(0);
  @override
  String get pem => '';
  @override
  Uint8List get sha1 => Uint8List(0);
  @override
  String get subject => '';
  @override
  String get issuer => '';
  @override
  DateTime get startValidity => DateTime.fromMillisecondsSinceEpoch(0);
  @override
  DateTime get endValidity => DateTime.fromMillisecondsSinceEpoch(0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DebugCertOverride (FIX-A)', () {
    test('Debug mode (asserts active) enables bypass without env flag', () {
      // flutter test runs with asserts enabled, so isDebug is true and the
      // bypass must be active even though ALLOW_DEBUG_CERT is unset.
      final callback = DebugCertOverride.getCallback('https://example.com');
      expect(callback, isNotNull);
    });

    test('Callback accepts every host (no host matching, redirect-safe)', () {
      final cert = _FakeX509Certificate();
      final callback = DebugCertOverride.getCallback(
        'https://example.com',
        allowDebugCertOverride: true,
      )!;
      // The redirect target host never matches the original URL's host —
      // the bypass must still accept it (this is what broke with host matching).
      expect(callback(cert, 'cdn.redirect-host.com', 443), isTrue);
      expect(callback(cert, 'example.com', 443), isTrue);
      expect(callback(cert, '192.168.1.10', 8443), isTrue);
    });

    test('Explicit allowDebugCertOverride also enables bypass', () {
      final callback = DebugCertOverride.getCallback(
        'https://example.com',
        allowDebugCertOverride: true,
      );
      expect(callback, isNotNull);
    });
  });
}
