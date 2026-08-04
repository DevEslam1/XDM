import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/single_instance_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File tokenFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('single_instance_test_');
    tokenFile = File('${tempDir.path}/test_instance.token');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('SingleInstanceService Unit Tests', () {
    test('Two instances: second detects primary and exits', () async {
      final primary = SingleInstanceService.createForTest(customTokenFile: tokenFile);
      final isPrimary1 = await primary.initialize([]);
      expect(isPrimary1, isTrue);
      expect(await tokenFile.exists(), isTrue);

      final secondary = SingleInstanceService.createForTest(customTokenFile: tokenFile);
      final isPrimary2 = await secondary.initialize(['https://example.com/test.iso']);
      expect(isPrimary2, isFalse);

      primary.dispose();
      secondary.dispose();
    });

    test('Primary dies (no heartbeat / stale): second promotes itself', () async {
      // Simulate dead primary with stale heartbeat timestamp (100 seconds ago)
      final staleTimestamp = DateTime.now().subtract(const Duration(seconds: 100)).millisecondsSinceEpoch;
      await tokenFile.writeAsString('staleToken\n37128\n$staleTimestamp');

      final secondary = SingleInstanceService.createForTest(customTokenFile: tokenFile);
      final isPrimary = await secondary.initialize([]);
      expect(isPrimary, isTrue);

      secondary.dispose();
    });

    test('Token file is cleaned up on dispose', () async {
      final service = SingleInstanceService.createForTest(customTokenFile: tokenFile);
      await service.initialize([]);
      expect(await tokenFile.exists(), isTrue);

      service.dispose();
      expect(await tokenFile.exists(), isFalse);
    });
  });
}
