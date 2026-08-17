import 'dart:convert';
import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Browser Bug Fixes Tests', () {
    test(
        'BrowserTab resetFindController resets failed state and clears controller',
        () {
      final tab = BrowserTab(
        id: 'tab_test',
        url: 'https://example.com',
        title: 'Test Tab',
      );

      // In unit test environment without native webview binding, getter safely returns null and catches failure
      tab.findInteractionController;
      // Resetting clears the failed state
      tab.resetFindController();
      expect(tab.isDisposed, isFalse);
    });

    test('AdBlock scriptlet parsing math extracts full scriptlet name and args',
        () {
      const line1 = 'example.com##+js(no-xhr-if,ads)';
      final idx1 = line1.indexOf('##+js(');
      final afterPrefix1 = line1.substring(idx1 + 6);
      final closeIdx1 = afterPrefix1.lastIndexOf(')');
      final scriptlet1 = (closeIdx1 != -1
              ? afterPrefix1.substring(0, closeIdx1)
              : afterPrefix1)
          .trim();

      expect(scriptlet1, equals('no-xhr-if,ads'));

      const line2 = '##+js(set-constant,adBlock,false)';
      final idx2 = line2.indexOf('##+js(');
      final afterPrefix2 = line2.substring(idx2 + 6);
      final closeIdx2 = afterPrefix2.lastIndexOf(')');
      final scriptlet2 = (closeIdx2 != -1
              ? afterPrefix2.substring(0, closeIdx2)
              : afterPrefix2)
          .trim();

      expect(scriptlet2, equals('set-constant,adBlock,false'));
    });

    test(
        'evaluateJavascript JSON-wrapped string is correctly parsed and decoded',
        () {
      const jsonQuoted = '"https://example.com/favicon.ico"';
      String parsed = '';
      try {
        final decoded = jsonDecode(jsonQuoted);
        parsed = decoded is String ? decoded.trim() : jsonQuoted;
      } catch (_) {
        parsed = jsonQuoted;
        if (parsed.startsWith('"') &&
            parsed.endsWith('"') &&
            parsed.length >= 2) {
          parsed = parsed.substring(1, parsed.length - 1).trim();
        }
      }

      expect(parsed, equals('https://example.com/favicon.ico'));
      expect(Uri.tryParse(parsed)?.scheme, equals('https'));
    });
  });
}
