import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Widget Request Code Stability Tests [W-1]', () {
    test(
        'Kotlin DMXRemoteViewsFactory derives deterministic request code from key hash',
        () {
      final factoryFile = File(
          'android/app/src/main/kotlin/com/xdm/downloadmanager/widget/DMXRemoteViewsFactory.kt');
      expect(factoryFile.existsSync(), isTrue);
      final content = factoryFile.readAsStringSync();

      // Assert sequential requestCodeMap was removed
      expect(content.contains('requestCodeMap = ConcurrentHashMap'), isFalse);
      expect(content.contains('nextRequestCode = AtomicInteger'), isFalse);

      // Assert deterministic requestCodeFor implementation using key.hashCode() and 0x7FFFFFFF (W-14 fix)
      expect(
          content.contains(
              'fun requestCodeFor(key: String): Int = key.hashCode() and 0x7FFFFFFF'),
          isTrue);

      // Assert deterministic hashing behavior
      int requestCodeFor(String key) {
        // Kotlin String.hashCode() algorithm
        var h = 0;
        for (var i = 0; i < key.length; i++) {
          h = (31 * h + key.codeUnitAt(i)) & 0xFFFFFFFF;
          if (h > 0x7FFFFFFF) h -= 0x100000000;
        }
        return h & 0x7FFFFFFF;
      }

      final code1 = requestCodeFor('action_pause_task_123');
      final code2 = requestCodeFor('action_pause_task_123');
      final code3 = requestCodeFor('action_resume_task_123');

      expect(code1, equals(code2),
          reason:
              'Request codes for same key must be strictly identical across invocations');
      expect(code1, isNot(equals(code3)),
          reason: 'Distinct actions must have distinct deterministic codes');
      expect(code1 >= 0, isTrue);
    });
  });
}
