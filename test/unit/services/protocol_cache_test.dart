import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dmx/core/services/protocol_cache.dart';
import 'package:dmx/core/services/protocol_fallback_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProtocolCache & ProtocolFallbackMemory Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ProtocolCache.init();
    });

    test('ProtocolCache records and retrieves host capabilities', () async {
      const url = 'https://example.com/file.zip';
      expect(ProtocolCache.get(url), isNull);

      await ProtocolCache.record(url, ProtocolSupport.http3);
      expect(ProtocolCache.get(url), equals(ProtocolSupport.http3));
    });

    test('ProtocolFallbackMemory records HTTP/3 failures correctly', () {
      const url = 'https://flaky-h3-server.org/data.bin';
      expect(
        ProtocolFallbackMemory.recentlyFailed(url, ProtocolSupport.http3),
        isFalse,
      );

      ProtocolFallbackMemory.recordFailure(url, ProtocolSupport.http3);
      expect(
        ProtocolFallbackMemory.recentlyFailed(url, ProtocolSupport.http3),
        isTrue,
      );

      expect(
        ProtocolFallbackMemory.recentlyFailed(url, ProtocolSupport.http2),
        isFalse,
      );
    });
  });
}
