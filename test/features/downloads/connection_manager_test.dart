import 'package:dmx/core/services/connection_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ConnectionManager Hardening (Sprint 2)', () {
    test('Probes cache enforces 150 cap', () {
      final manager = ConnectionManager();

      // Record probes for 160 hosts directly
      for (int i = 1; i <= 160; i++) {
        manager.recordProbeForTesting('testhost$i.com', i.isEven);
      }

      expect(manager.probesCountForTesting, equals(150));
      manager.clearCache();
    });
  });
}
