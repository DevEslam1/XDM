import 'package:dmx/core/services/user_script_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UserScriptManager.resetInstance();
  });

  group('UserScriptManager & Sandbox Hardening', () {
    test('Script with eval or Function is rejected during validation', () {
      final manager = UserScriptManager();

      const invalidScript = UserScript(
        id: 'bad_1',
        name: 'Eval Attack',
        urlPattern: '*',
        code: 'eval("console.log(1)");',
      );

      expect(() => manager.add(invalidScript), throwsA(isA<Exception>()));
    });

    test('Script with new Function is rejected during validation', () {
      final manager = UserScriptManager();

      const invalidScript = UserScript(
        id: 'bad_2',
        name: 'Function Attack',
        urlPattern: '*',
        code: 'var f = new Function("return 42");',
      );

      expect(() => manager.add(invalidScript), throwsA(isA<Exception>()));
    });

    test('Sandbox JS generation includes network and cookie blocking wrappers',
        () async {
      final manager = UserScriptManager();
      const script = UserScript(
        id: 's1',
        name: 'Test Script',
        urlPattern: 'https://example.com/*',
        code: 'console.log("Hello");',
        permissions: {ScriptPermission.domRead},
      );

      await manager.add(script);
      final js = await manager.getJsForUrl('https://example.com/test');

      expect(js, contains('parent'));
      expect(js, contains('Cookie access denied'));
      expect(js, contains('Network fetch denied'));
    });

    test('Glob pattern matching works accurately', () {
      expect(
        UserScriptManager.matchesPattern(
            'https://example.com/*', 'https://example.com/page'),
        isTrue,
      );
      expect(
        UserScriptManager.matchesPattern(
            'https://other.com/*', 'https://example.com/page'),
        isFalse,
      );
    });
  });
}
