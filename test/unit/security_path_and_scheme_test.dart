import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/utils/file_utils.dart';
import 'package:dmx/features/browser/services/page_intent_classifier.dart';

void main() {
  group('Security Sanitization Tests (SEC-02 / SEC-03)', () {
    test('safeFileName sanitizes path traversal sequences (SEC-02)', () {
      expect(safeFileName('../../etc/passwd'), equals('etc_passwd'));
      expect(safeFileName('..\\..\\windows\\system32\\calc.exe'),
          equals('windows_system32_calc.exe'));
      expect(safeFileName('foo/bar/baz.zip'), equals('foo_bar_baz.zip'));
      expect(safeFileName('file\x00with\x1Fnulls.txt'),
          equals('filewithnulls.txt'));
    });

    test('safeFileName sanitizes Windows reserved names (SEC-02)', () {
      expect(safeFileName('CON.txt'), equals('_CON.txt'));
      expect(safeFileName('aux.pdf'), equals('_aux.pdf'));
      expect(safeFileName('NUL'), equals('_NUL'));
      expect(safeFileName('com1.zip'), equals('_com1.zip'));
      expect(safeFileName('lpt1.iso'), equals('_lpt1.iso'));
    });

    test(
        'PageIntentClassifier blocks unsafe schemes and allows whitelisted (SEC-03)',
        () {
      final classifier = PageIntentClassifier.instance;

      // Whitelisted schemes
      expect(
          PageIntentClassifier.isAllowedScheme('https://example.com/file.zip'),
          isTrue);
      expect(
          PageIntentClassifier.isAllowedScheme(
              'http://example.com/archive.tar'),
          isTrue);
      expect(
          PageIntentClassifier.isAllowedScheme(
              'magnet:?xt=urn:btih:1234567890'),
          isTrue);

      // Dangerous schemes
      expect(
          PageIntentClassifier.isAllowedScheme('javascript:alert(1)'), isFalse);
      expect(
          PageIntentClassifier.isAllowedScheme(
              'data:text/html;base64,PHNjcmlwdD4='),
          isFalse);
      expect(
          PageIntentClassifier.isAllowedScheme('blob:https://example.com/uuid'),
          isFalse);
      expect(
          PageIntentClassifier.isAllowedScheme('file:///etc/passwd'), isFalse);
      expect(
          PageIntentClassifier.isAllowedScheme(
              'intent://scan/#Intent;scheme=zxing;package=com.google.zxing.client.android;end'),
          isFalse);

      final blockedJs =
          classifier.classify('javascript:alert(document.cookie)');
      expect(blockedJs.shouldBlock, isTrue);

      final blockedFile = classifier.classify('file:///etc/shadow');
      expect(blockedFile.shouldBlock, isTrue);
    });
  });
}
