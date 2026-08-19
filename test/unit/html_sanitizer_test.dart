import 'package:dmx/features/browser/services/html_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HtmlSanitizer Security & Performance Tests', () {
    test('strips simple and multiline <script> tags', () {
      const input = '<div>Hello <script>alert("xss")</script> World</div>';
      final output = HtmlSanitizer.sanitize(input);
      expect(output, isNot(contains('<script>')));
      expect(output, isNot(contains('alert')));
      expect(output, contains('<div>Hello  World</div>'));
    });

    test('strips nested script evasion techniques', () {
      const input = '<scr<script>ipt>alert(1)</script>';
      final output = HtmlSanitizer.sanitize(input);
      expect(output.toLowerCase(), isNot(contains('<script>')));
      expect(output.toLowerCase(), isNot(contains('alert(1)')));
    });

    test('strips inline event handlers (onerror, onload, onclick, onmouseover)', () {
      const input = '''
        <img src="valid.png" onerror="alert('pwnd')">
        <button onclick="stealCookies()">Click</button>
        <div onmouseover="payload()">Hover</div>
      ''';
      final output = HtmlSanitizer.sanitize(input);
      expect(output, isNot(contains('onerror')));
      expect(output, isNot(contains('onclick')));
      expect(output, isNot(contains('onmouseover')));
    });

    test('strips javascript: and dangerous data: URIs from anchors', () {
      const input = '<a href="javascript:alert(1)">Click Here</a>';
      final output = HtmlSanitizer.sanitize(input);
      expect(output, isNot(contains('javascript:')));
    });

    test('strips dangerous embedded elements: iframe, object, embed, svg, form', () {
      const input = '''
        <iframe>evil</iframe>
        <object data="flash.swf"></object>
        <embed src="movie.swf">
        <svg onload="alert(1)"><circle /></svg>
        <form action="/login"><input type="text"/></form>
      ''';
      final output = HtmlSanitizer.sanitize(input);
      expect(output, isNot(contains('<iframe')));
      expect(output, isNot(contains('<object')));
      expect(output, isNot(contains('<embed')));
      expect(output, isNot(contains('<svg')));
      expect(output, isNot(contains('<form')));
    });

    test('sanitizes asynchronously via sanitizeAsync', () async {
      final largeInput = '<p>Safe text</p><script>evil()</script>' * 200;
      final output = await HtmlSanitizer.sanitizeAsync(largeInput);
      expect(output, isNot(contains('<script>')));
      expect(output, contains('<p>Safe text</p>'));
    });

    test('escapeHtml properly escapes XML entities', () {
      const input = '<div class="test" data-item=\'foo\'>A & B</div>';
      final escaped = HtmlSanitizer.escapeHtml(input);
      expect(escaped, isNot(contains('<div')));
      expect(escaped, contains('&lt;div'));
      expect(escaped, contains('&amp;'));
      expect(escaped, contains('&quot;'));
      expect(escaped, contains('&#39;'));
    });
  });
}
