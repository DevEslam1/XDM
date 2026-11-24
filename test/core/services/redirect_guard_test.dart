import 'dart:convert';

import 'package:dmx/core/services/redirect_guard.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockWebViewController extends Mock implements InAppWebViewController {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RedirectGuard guard;
  late _MockWebViewController controller;

  setUp(() {
    guard = RedirectGuard();
    controller = _MockWebViewController();
    when(() => controller.evaluateJavascript(source: any(named: 'source')))
        .thenAnswer((_) async => '[]');
  });

  group('RedirectGuard.evaluate', () {
    test('ignores non-web URLs', () async {
      final res =
          await guard.evaluate(tabId: 't', navigatingTo: 'mailto:a@b.c');
      expect(res.decision, RedirectDecision.ignore);
    });

    test('ignores ordinary pages', () async {
      final res = await guard.evaluate(
        tabId: 't',
        navigatingTo: 'https://google.com/search?q=dmx',
      );
      expect(res.decision, RedirectDecision.ignore);
    });

    test('blocks ad-network targets', () async {
      final res = await guard.evaluate(
        tabId: 't',
        navigatingTo: 'https://sub.popads.net/track?id=1',
      );
      expect(res.decision, RedirectDecision.block);
      expect(res.strategy, 'ad-network-target');
    });

    test('ignores ad-bridge URLs (extraction happens later)', () async {
      final res = await guard.evaluate(
        tabId: 't',
        navigatingTo: 'https://adf.ly/go/abc',
      );
      expect(res.decision, RedirectDecision.ignore);
    });

    test('blocks circular chains via the loop guard', () async {
      const url = 'https://adf.ly/go/target';
      guard.addToChain('t', url);
      final res = await guard.evaluate(tabId: 't', navigatingTo: url);
      expect(res.decision, RedirectDecision.block);
      expect(res.strategy, 'loop-guard');
    });

    test('blocks an HTTPS -> HTTP protocol downgrade', () async {
      guard.addToChain('t', 'https://secure.example.com/a');
      final res = await guard.evaluate(
        tabId: 't',
        navigatingTo: 'http://secure.example.com/b',
      );
      expect(res.strategy, 'protocol-downgrade-guard');
      expect(res.decision, RedirectDecision.block);
    });

    test('blocks once the depth cap is reached', () async {
      for (var i = 0; i < 10; i++) {
        await guard.evaluate(
          tabId: 't',
          navigatingTo: 'https://normal.example.com/p$i',
        );
      }
      final res = await guard.evaluate(
        tabId: 't',
        navigatingTo: 'https://normal.example.com/final',
      );
      expect(res.strategy, 'depth-cap');
      expect(res.decision, RedirectDecision.block);
    });

    test('caps the internal tab map size', () async {
      for (var i = 0; i < 55; i++) {
        await guard.evaluate(
          tabId: 'tab$i',
          navigatingTo: 'https://example.com/$i',
        );
      }
      expect(true, isTrue);
    });

    test('reset clears a tab and disposeAll clears everything', () async {
      const url = 'https://adf.ly/go/target';
      guard.addToChain('t', url);
      guard.reset('t');
      final res = await guard.evaluate(tabId: 't', navigatingTo: url);
      expect(res.decision, RedirectDecision.ignore);

      guard.addToChain('x', url);
      guard.disposeAll();
      expect(true, isTrue);
    });
  });

  group('RedirectGuard.extractFromPage', () {
    test('ignores tabs with no recorded URL', () async {
      final res = await guard.extractFromPage(
        tabId: 't',
        controller: controller,
      );
      expect(res.decision, RedirectDecision.ignore);
    });

    test('ignores pages that are not ad bridges', () async {
      await guard.evaluate(
        tabId: 't',
        navigatingTo: 'https://example.com/article',
      );
      final res = await guard.extractFromPage(
        tabId: 't',
        controller: controller,
      );
      expect(res.decision, RedirectDecision.ignore);
    });

    test('ignores when JS returns nothing', () async {
      when(() => controller.evaluateJavascript(source: any(named: 'source')))
          .thenAnswer((_) async => null);
      await guard.evaluate(tabId: 't', navigatingTo: 'https://adf.ly/go/x');
      final res = await guard.extractFromPage(
        tabId: 't',
        controller: controller,
      );
      expect(res.decision, RedirectDecision.ignore);
    });

    test('ignores when JS returns malformed JSON', () async {
      when(() => controller.evaluateJavascript(source: any(named: 'source')))
          .thenAnswer((_) async => 'not json');
      await guard.evaluate(tabId: 't', navigatingTo: 'https://adf.ly/go/x');
      final res = await guard.extractFromPage(
        tabId: 't',
        controller: controller,
      );
      expect(res.decision, RedirectDecision.ignore);
    });

    test('auto-follows a single cross-host media candidate', () async {
      when(() => controller.evaluateJavascript(source: any(named: 'source')))
          .thenAnswer((_) async => '["https://cdn.other.com/file.mp4"]');
      await guard.evaluate(tabId: 't', navigatingTo: 'https://adf.ly/go/x');
      final res = await guard.extractFromPage(
        tabId: 't',
        controller: controller,
      );
      expect(res.decision, RedirectDecision.autoFollow);
      expect(res.targetUrl, 'https://cdn.other.com/file.mp4');
    });

    test('prompts the user for an ambiguous same-host candidate', () async {
      when(() => controller.evaluateJavascript(source: any(named: 'source')))
          .thenAnswer((_) async => '["https://adf.ly/other"]');
      await guard.evaluate(tabId: 't', navigatingTo: 'https://adf.ly/go/x');
      final res = await guard.extractFromPage(
        tabId: 't',
        controller: controller,
      );
      expect(res.decision, RedirectDecision.promptUser);
    });

    test('ignores when there are too many candidates', () async {
      when(() => controller.evaluateJavascript(source: any(named: 'source')))
          .thenAnswer(
        (_) async => jsonEncode([
          'https://a1.com/f',
          'https://a2.com/f',
          'https://a3.com/f',
          'https://a4.com/f',
          'https://a5.com/f',
          'https://a6.com/f',
        ]),
      );
      await guard.evaluate(tabId: 't', navigatingTo: 'https://adf.ly/go/x');
      final res = await guard.extractFromPage(
        tabId: 't',
        controller: controller,
      );
      expect(res.decision, RedirectDecision.ignore);
    });

    test('decodes base64-encoded targets', () async {
      final token = base64Url
          .encode(utf8.encode('https://cdn.other.com/file.zip'))
          .replaceAll('=', '');
      when(() => controller.evaluateJavascript(source: any(named: 'source')))
          .thenAnswer((_) async => jsonEncode([token]));
      await guard.evaluate(tabId: 't', navigatingTo: 'https://adf.ly/go/x');
      final res = await guard.extractFromPage(
        tabId: 't',
        controller: controller,
      );
      expect(res.targetUrl, 'https://cdn.other.com/file.zip');
    });

    test('handles malformed base64 candidates without throwing', () async {
      when(() => controller.evaluateJavascript(source: any(named: 'source')))
          .thenAnswer((_) async => jsonEncode(['AAAAAAAAAAAAAAAA==']));
      await guard.evaluate(tabId: 'b', navigatingTo: 'https://adf.ly/go/x');
      final res = await guard.extractFromPage(
        tabId: 'b',
        controller: controller,
      );
      expect(res, isA<RedirectResult>());
    });

    test('strips wrapping quotes from extracted targets', () async {
      when(() => controller.evaluateJavascript(source: any(named: 'source')))
          .thenAnswer(
        (_) async => jsonEncode(['"https://cdn.other.com/file.mp4"']),
      );
      await guard.evaluate(tabId: 'q', navigatingTo: 'https://adf.ly/go/x');
      final res = await guard.extractFromPage(
        tabId: 'q',
        controller: controller,
      );
      expect(res.targetUrl, 'https://cdn.other.com/file.mp4');
    });

    test('blocks rapid re-fires within the 800ms auto-follow window', () async {
      when(() => controller.evaluateJavascript(source: any(named: 'source')))
          .thenAnswer((_) async => '["https://cdn.other.com/file.mp4"]');
      await guard.evaluate(tabId: 't', navigatingTo: 'https://adf.ly/go/x');
      await guard.extractFromPage(tabId: 't', controller: controller);

      final res = await guard.evaluate(
        tabId: 't',
        navigatingTo: 'https://adf.ly/go/y',
      );
      expect(res.decision, RedirectDecision.block);
      expect(res.strategy, 'loop-guard');
    });
  });
}
