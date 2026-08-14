import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/redirect_guard.dart';

void main() {
  group('RedirectGuard Heuristics', () {
    late RedirectGuard guard;

    setUp(() {
      guard = RedirectGuard();
    });

    test('ignores standard legitimate URLs', () async {
      final res = await guard.evaluate(
        tabId: 'tab1',
        navigatingTo: 'https://google.com/search?q=test',
      );
      expect(res.decision, RedirectDecision.ignore);
    });

    test('flags ad networks for blocking', () async {
      final res = await guard.evaluate(
        tabId: 'tab1',
        navigatingTo: 'https://popads.net/track?id=123',
      );
      expect(res.decision, RedirectDecision.block);
    });

    test('loop guard blocks identical sequential navigations', () async {
      const url = 'https://adf.ly/go/target';
      guard.addToChain('tab1', url);

      final res = await guard.evaluate(tabId: 'tab1', navigatingTo: url);
      expect(res.decision, RedirectDecision.block);
    });

    test('reset clears loop history for the tab', () async {
      const url = 'https://adf.ly/go/target';
      guard.addToChain('tab1', url);

      guard.reset('tab1');

      final res = await guard.evaluate(tabId: 'tab1', navigatingTo: url);
      expect(res.decision, RedirectDecision.ignore);
    });

    test('circular redirect chain (A -> B -> A) is blocked (N-02)', () async {
      guard.addToChain('tab2', 'https://siteA.com');
      guard.addToChain('tab2', 'https://siteB.com');

      final res = await guard.evaluate(
          tabId: 'tab2', navigatingTo: 'https://siteA.com');
      expect(res.decision, RedirectDecision.block);
    });

    test('protocol downgrade (HTTPS -> HTTP) is blocked (N-03)', () async {
      guard.addToChain('tab3', 'https://secure.example.com');

      final res = await guard.evaluate(
          tabId: 'tab3', navigatingTo: 'http://insecure.example.com');
      expect(res.decision, RedirectDecision.block);
    });
  });
}
