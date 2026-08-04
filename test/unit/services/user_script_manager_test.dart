import 'package:dmx/core/services/user_script_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UserScriptManager.resetInstance();
  });

  UserScript script0({
    String id = 's1',
    String name = 'Test',
    String pattern = '*://*.example.com/*',
    String code = 'console.log("hi");',
    bool isCss = false,
    bool enabled = true,
  }) =>
      UserScript(
        id: id,
        name: name,
        urlPattern: pattern,
        code: code,
        isCss: isCss,
        enabled: enabled,
      );

  test('url matching: wildcard pattern matches host and full url', () {
    expect(
      UserScriptManager.matchesPattern(
        '*://*.example.com/*',
        'https://sub.example.com/page.html',
      ),
      isTrue,
    );
    expect(
      UserScriptManager.matchesPattern('example.com/*', 'https://example.com/'),
      isTrue,
    );
    expect(
      UserScriptManager.matchesPattern(
        '*youtube.com/watch*',
        'https://www.youtube.com/watch?v=abc',
      ),
      isTrue,
    );
    expect(
      UserScriptManager.matchesPattern('example.com', 'https://example.org/'),
      isFalse,
    );
  });

  test('url matching is case-insensitive', () {
    expect(
      UserScriptManager.matchesPattern(
        'EXAMPLE.com/*',
        'https://example.com/Path',
      ),
      isTrue,
    );
  });

  test('add, toggle and remove persist and are reflected', () async {
    final manager = UserScriptManager.instance;
    // Force a reload to pick up the fresh mock prefs.
    await manager.load();

    await manager.add(script0());
    expect(manager.scripts.length, 1);

    await manager.toggle('s1', false);
    expect(manager.scripts.first.enabled, isFalse);

    await manager.update(script0(name: 'Renamed'));
    expect(manager.scripts.first.name, 'Renamed');

    await manager.remove('s1');
    expect(manager.scripts, isEmpty);

    await manager.clear();
  });

  test('scriptsForUrl only returns enabled matching scripts', () async {
    final manager = UserScriptManager.instance;
    await manager.load();

    await manager.add(script0(id: 'match', pattern: 'example.com/*'));
    await manager.add(
      script0(id: 'disabled', pattern: 'example.com/*', enabled: false),
    );
    await manager.add(
      script0(id: 'other', pattern: 'other.org/*', isCss: true),
    );

    final matches = manager.scriptsForUrl('https://example.com/foo');
    expect(matches.length, 1);
    expect(matches.first.id, 'match');

    await manager.clear();
  });

  test(
    'scripts persist across manager instances via SharedPreferences',
    () async {
      final manager = UserScriptManager();
      await manager.load();
      await manager.add(script0());

      final fresh = UserScriptManager();
      await fresh.load();
      expect(fresh.scripts.length, 1);
      expect(fresh.scripts.first.name, 'Test');

      await fresh.clear();
    },
  );

  test('UserScript serialization round-trip', () {
    const script = UserScript(
      id: 'x1',
      name: 'Dark mode',
      urlPattern: '*://*.site.com/*',
      code: 'document.body.style.background = "black";',
      isCss: false,
      enabled: true,
    );
    final restored = UserScript.fromJson(script.toJson());
    expect(restored.id, script.id);
    expect(restored.name, script.name);
    expect(restored.urlPattern, script.urlPattern);
    expect(restored.code, script.code);
    expect(restored.isCss, script.isCss);
    expect(restored.enabled, script.enabled);
  });

  test('sandbox string neutralizes DOM write when domWrite permission is absent', () async {
    const script = UserScript(
      id: 'no_dom',
      name: 'No DOM Write',
      urlPattern: '*',
      code: 'document.write("evil");',
      permissions: {ScriptPermission.domRead},
    );
    final manager = UserScriptManager.instance;
    await manager.load();
    await manager.add(script);
    final outputJs = await manager.getJsForUrl('https://example.com');
    expect(outputJs, contains('document.write'));
    expect(outputJs, contains("'fetch'"));
    expect(outputJs, contains("'XMLHttpRequest'"));
    await manager.clear();
  });

  test('script id marker is safely escaped in sandbox key', () async {
    const script = UserScript(
      id: 'bad;id"with-special@chars',
      name: 'Special ID',
      urlPattern: '*',
      code: 'console.log(1);',
    );
    final manager = UserScriptManager.instance;
    await manager.load();
    await manager.add(script);
    final js = await manager.getJsForUrl('https://example.com');
    expect(js, contains('xdm_user_script_bad_id_with_special_chars'));
    await manager.clear();
  });
}
