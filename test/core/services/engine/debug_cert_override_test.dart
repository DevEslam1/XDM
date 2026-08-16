import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DebugCertOverride (P0-5)', () {
    test('Default gating without ALLOW_DEBUG_CERT returns null callback', () {
      final callback = DebugCertOverride.getCallback('https://example.com');
      expect(callback, isNull);
    });

    test('When allowDebugCertOverride is false, callback is null', () {
      final callback = DebugCertOverride.getCallback(
        'https://example.com',
        allowDebugCertOverride: false,
      );
      expect(callback, isNull);
    });

    test(
        'When allowDebugCertOverride is true in non-release mode, callback returns matcher',
        () {
      final callback = DebugCertOverride.getCallback(
        'https://example.com',
        allowDebugCertOverride: true,
      );
      expect(callback, isNotNull);
    });
  });
}
