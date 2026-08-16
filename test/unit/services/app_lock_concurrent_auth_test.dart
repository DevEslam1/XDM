import 'package:dmx/core/services/app_lock_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (methodCall) async {
        if (methodCall.method == 'read') {
          final args = methodCall.arguments as Map<dynamic, dynamic>?;
          final key = args?['key'];
          if (key == 'xdm_app_lock_enabled') return 'true';
        }
        return null;
      },
    );
  });

  group('AppLockService Concurrent Authentication Deduplication (E1)', () {
    test(
        '5 concurrent authenticate calls trigger exactly 1 prompt and all resolve with same result',
        () async {
      int promptCount = 0;

      Future<bool> mockPromptAction() async {
        promptCount++;
        await Future.delayed(const Duration(milliseconds: 50));
        return true;
      }

      // Fire 5 concurrent authentication calls simultaneously
      final futures = List.generate(
        5,
        (_) => AppLockService.authenticate(authAction: mockPromptAction),
      );

      final results = await Future.wait(futures);

      // Exactly 1 action execution
      expect(promptCount, equals(1));
      // All 5 callers get the exact same successful result
      expect(results, equals([true, true, true, true, true]));
    });
  });
}
