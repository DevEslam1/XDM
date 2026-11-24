import 'dart:typed_data';

import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeController implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePullToRefresh implements PullToRefreshController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('BrowserTabUiState Tests', () {
    test('faviconBytes copies valid buffers, rejects empty and oversized', () {
      final state = BrowserTabUiState();
      expect(state.faviconBytesSize, 0);

      final source = Uint8List.fromList([1, 2, 3]);
      state.faviconBytes = source;
      expect(state.faviconBytes, isNotNull);
      expect(identical(state.faviconBytes, source), isFalse);
      expect(state.faviconBytesSize, 3);

      state.faviconBytes = Uint8List(0);
      expect(state.faviconBytes, isNull);

      state.faviconBytes = Uint8List(600 * 1024);
      expect(state.faviconBytes, isNull);

      state.faviconBytes = null;
      expect(state.faviconBytes, isNull);
    });

    test('defaults lastVisitedAtMs to now when not supplied', () {
      final before = DateTime.now().millisecondsSinceEpoch;
      final state = BrowserTabUiState();
      expect(state.lastVisitedAtMs, greaterThanOrEqualTo(before));
      final explicit = BrowserTabUiState(lastVisitedAtMs: 42);
      expect(explicit.lastVisitedAtMs, 42);
    });
  });

  group('BrowserTabWebViewState Tests', () {
    test('progress and isLoading only notify on change', () {
      final state = BrowserTabWebViewState();
      var progressNotifies = 0;
      var loadingNotifies = 0;
      state.progressNotifier.addListener(() => progressNotifies++);
      state.loadingNotifier.addListener(() => loadingNotifies++);

      state.progress = 0.0;
      expect(progressNotifies, 0);
      state.progress = 0.5;
      expect(progressNotifies, 1);
      expect(state.progress, 0.5);

      state.isLoading = false;
      expect(loadingNotifies, 0);
      state.isLoading = true;
      expect(loadingNotifies, 1);
      expect(state.isLoading, isTrue);
    });

    test('setUrl updates the url notifier and skips identical values', () {
      final state = BrowserTabWebViewState(initialUrl: 'https://a.com');
      var notifies = 0;
      state.urlNotifier.addListener(() => notifies++);

      state.setUrl('https://a.com');
      expect(notifies, 0);
      state.setUrl('https://b.com');
      expect(notifies, 1);
      expect(state.urlNotifier.value, 'https://b.com');
    });

    test('findInteractionController can be reset without throwing', () {
      final state = BrowserTabWebViewState();
      // Constructing a FindInteractionController may fail in the test
      // environment; the getter must degrade gracefully.
      state.findInteractionController;
      state.resetFindController();
      state.findInteractionController;
      expect(state.isDisposed, isFalse);
    });

    test('dispose is idempotent and guards setters afterwards', () {
      final state = BrowserTabWebViewState(
        controller: _FakeController(),
        pullToRefreshController: _FakePullToRefresh(),
        initialProgress: 0.25,
        initialLoading: true,
      );

      state.dispose();
      expect(state.isDisposed, isTrue);
      expect(state.controller, isNull);
      expect(state.pullToRefreshController, isNull);

      // Setters assert in debug builds once the state is disposed.
      expect(() => state.progress = 0.9, throwsA(isA<AssertionError>()));
      expect(() => state.isLoading = false, throwsA(isA<AssertionError>()));
      expect(() => state.setUrl('https://after-dispose.com'),
          throwsA(isA<AssertionError>()));

      state.dispose();
    });
  });

  group('BrowserTab Delegate Tests', () {
    test('identity and webview delegates round-trip values', () {
      final tab = BrowserTab(
        id: 'tab-1',
        url: 'https://example.com',
        title: 'Example',
        isIncognito: true,
        origin: TabOrigin.redirect,
        createdAtMs: 123,
      );

      expect(tab.id, 'tab-1');
      expect(tab.createdAtMs, 123);
      expect(tab.isIncognito, isTrue);
      expect(tab.origin, TabOrigin.redirect);
      tab.origin = TabOrigin.adOrPopup;
      expect(tab.origin, TabOrigin.adOrPopup);

      tab.controller = _FakeController();
      expect(tab.controller, isNotNull);
      tab.controller = null;
      expect(tab.controller, isNull);

      tab.pullToRefreshController = _FakePullToRefresh();
      expect(tab.pullToRefreshController, isNotNull);
      tab.pullToRefreshController = null;

      int? captured;
      tab.onFindResultReceived = (ordinal, total, done) => captured = ordinal;
      expect(tab.onFindResultReceived, isNotNull);
      tab.onFindResultReceived!(7, 9, false);
      expect(captured, 7);
    });

    test('navigation/error flags can be toggled', () {
      final tab = BrowserTab(id: 'tab-1', url: 'https://example.com');

      tab.canGoBack = true;
      tab.canGoForward = true;
      tab.hasCrashed = true;
      tab.isTimedOut = true;
      tab.isSuspended = true;
      tab.hasError = true;
      tab.errorDescription = 'boom';
      tab.hasAttemptedSilentReload = true;
      tab.lastRenderedProgress = 42;

      expect(tab.canGoBack, isTrue);
      expect(tab.canGoForward, isTrue);
      expect(tab.hasCrashed, isTrue);
      expect(tab.isTimedOut, isTrue);
      expect(tab.isSuspended, isTrue);
      expect(tab.hasError, isTrue);
      expect(tab.errorDescription, 'boom');
      expect(tab.hasAttemptedSilentReload, isTrue);
      expect(tab.lastRenderedProgress, 42);
    });

    test('progress, loading and url delegates proxy the webview state', () {
      final tab = BrowserTab(id: 'tab-1', url: 'https://example.com');
      tab.progress = 0.5;
      expect(tab.progress, 0.5);
      expect(tab.progressNotifier.value, 0.5);

      tab.isLoading = true;
      expect(tab.isLoading, isTrue);
      expect(tab.loadingNotifier.value, isTrue);

      tab.url = 'https://updated.example.com';
      expect(tab.url, 'https://updated.example.com');
    });

    test('ui state delegates round-trip values', () {
      final tab = BrowserTab(id: 'tab-1', url: 'https://example.com');

      tab.title = 'Title';
      tab.themeColor = Colors.red;
      tab.findQuery = 'query';
      tab.previewBytes = Uint8List.fromList([1]);
      tab.savedScrollY = 10;
      tab.tabGroupId = 'group';
      tab.hasVideoElement = true;
      tab.lastVisitedAtMs = 999;
      tab.lastVisitedAt = 1000;
      tab.faviconUrl = 'https://example.com/favicon.ico';
      tab.faviconBytes = Uint8List.fromList([1, 2, 3]);

      expect(tab.title, 'Title');
      expect(tab.themeColor, Colors.red);
      expect(tab.findQuery, 'query');
      expect(tab.previewBytes, isNotNull);
      expect(tab.savedScrollY, 10);
      expect(tab.tabGroupId, 'group');
      expect(tab.hasVideoElement, isTrue);
      expect(tab.lastVisitedAtMs, 1000);
      expect(tab.lastVisitedAt, 1000);
      expect(tab.faviconUrl, 'https://example.com/favicon.ico');
      expect(tab.faviconBytesSize, 3);
    });

    test('url helpers: isSecure, host, domain, stripLabel', () {
      final tab = BrowserTab(id: 'tab-1', url: 'https://www.example.com/page');
      expect(tab.isSecure, isTrue);
      expect(tab.host, 'www.example.com');
      expect(tab.domain, 'example.com');

      // stripLabel uses title when meaningful
      tab.title = 'My Page';
      expect(tab.stripLabel, 'My Page');

      // falls back to domain when title is empty
      tab.title = '';
      expect(tab.stripLabel, 'example.com');

      // home tab always reports Home
      final home = BrowserTab(id: 'tab-2', url: '');
      expect(home.stripLabel, 'Home');

      // insecure scheme
      final insecure = BrowserTab(id: 'tab-3', url: 'http://example.com');
      expect(insecure.isSecure, isFalse);
    });

    test('updateUrl normalizes and invalidates the host cache', () {
      final tab = BrowserTab(id: 'tab-1', url: 'https://a.com/x');
      expect(tab.host, 'a.com');

      tab.updateUrl('https://b.com/y');
      expect(tab.host, 'b.com');
      expect(tab.url, 'https://b.com/y');

      // Same URL is a no-op.
      tab.updateUrl('https://b.com/y');
      expect(tab.url, 'https://b.com/y');

      tab.updateUrl('');
      expect(tab.isHome, isTrue);
      expect(tab.host, '');
      expect(tab.domain, '');
    });

    test('dispose tears down webview state', () {
      final tab = BrowserTab(id: 'tab-1', url: 'https://example.com');
      tab.dispose();
      expect(tab.isDisposed, isTrue);
      // Setters guarded by isDisposed should be no-ops.
      tab.canGoBack = true;
      tab.hasError = true;
      expect(tab.canGoBack, isFalse);
      expect(tab.hasError, isFalse);
    });
  });
}
