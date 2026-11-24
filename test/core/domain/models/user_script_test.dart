import 'package:dmx/core/domain/models/user_script.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UserScript', () {
    test('constructor defaults', () {
      const s = UserScript(
        id: '1',
        name: 'n',
        urlPattern: '*',
        code: 'c',
      );
      expect(s.isCss, isFalse);
      expect(s.enabled, isTrue);
      expect(
          s.permissions, {ScriptPermission.domRead, ScriptPermission.domWrite});
    });

    test('copyWith', () {
      const s = UserScript(
        id: '1',
        name: 'n',
        urlPattern: '*',
        code: 'c',
      );
      final c = s.copyWith(
        name: 'n2',
        urlPattern: 'p',
        code: 'c2',
        isCss: true,
        enabled: false,
        permissions: const {ScriptPermission.network},
      );
      expect(c.id, '1');
      expect(c.name, 'n2');
      expect(c.urlPattern, 'p');
      expect(c.code, 'c2');
      expect(c.isCss, isTrue);
      expect(c.enabled, isFalse);
      expect(c.permissions, {ScriptPermission.network});

      expect(s.copyWith().name, 'n');
    });

    test('toJson / fromJson roundtrip', () {
      const s = UserScript(
        id: '1',
        name: 'n',
        urlPattern: 'p',
        code: 'c',
        isCss: true,
        enabled: false,
        permissions: {ScriptPermission.cookies, ScriptPermission.storage},
      );
      final json = s.toJson();
      expect(json['permissions'], containsAll(['cookies', 'storage']));

      final restored = UserScript.fromJson(json);
      expect(restored.id, '1');
      expect(restored.isCss, isTrue);
      expect(restored.enabled, isFalse);
      expect(restored.permissions,
          {ScriptPermission.cookies, ScriptPermission.storage});
    });

    test('fromJson defaults and unknown permission fallback', () {
      final missing = UserScript.fromJson(const {});
      expect(missing.id, '');
      expect(missing.enabled, isTrue);
      expect(missing.permissions,
          {ScriptPermission.domRead, ScriptPermission.domWrite});

      final unknownPerm = UserScript.fromJson(const {
        'permissions': ['bogus'],
      });
      expect(unknownPerm.permissions, {ScriptPermission.domRead});
    });
  });
}
