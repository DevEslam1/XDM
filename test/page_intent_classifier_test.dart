import 'package:dmx/features/browser/services/browser_detector.dart';
import 'package:dmx/features/browser/services/page_intent_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PageIntentClassifier Tests', () {
    final classifier = PageIntentClassifier.instance;

    test('Magnet links are classified as magnetPage and openNewTabWithDownloadSuggestion', () {
      final res = classifier.classify('magnet:?xt=urn:btih:1234567890abcdef&dn=Ubuntu');
      expect(res.intent, PageIntent.magnetPage);
      expect(res.action, PageAction.openNewTabWithDownloadSuggestion);
      expect(res.confidence, greaterThanOrEqualTo(0.9));
      expect(res.mediaKind, DetectedMediaKind.magnet);
    });

    test('Torrent file URLs are classified as magnetPage and openNewTabWithDownloadSuggestion', () {
      final res = classifier.classify('https://example.com/files/ubuntu.torrent');
      expect(res.intent, PageIntent.magnetPage);
      expect(res.action, PageAction.openNewTabWithDownloadSuggestion);
      expect(res.mediaKind, DetectedMediaKind.torrent);
    });

    test('Direct archive/executable download URLs are classified as directDownload', () {
      final exe = classifier.classify('https://example.com/software/setup.exe');
      expect(exe.intent, PageIntent.directDownload);
      expect(exe.action, PageAction.directDownload);

      final zip = classifier.classify('https://example.com/archive/files.zip');
      expect(zip.intent, PageIntent.directDownload);
      expect(zip.action, PageAction.directDownload);

      final apk = classifier.classify('https://example.com/apps/game.apk');
      expect(apk.intent, PageIntent.directDownload);
      expect(apk.action, PageAction.directDownload);
    });

    test('PDF documents are classified as filePage with download suggestion', () {
      final res = classifier.classify('https://example.com/document.pdf');
      expect(res.intent, PageIntent.filePage);
      expect(res.action, PageAction.openNewTabWithDownloadSuggestion);
    });

    test('Media files (mp4) are classified as mediaPage with download suggestion', () {
      final res = classifier.classify('https://example.com/video.mp4');
      expect(res.intent, PageIntent.mediaPage);
      expect(res.action, PageAction.openNewTabWithDownloadSuggestion);
    });

    test('Ad domains are classified as adPage and blocked when not user click', () {
      final res = classifier.classifyWithContext(
        currentUrl: 'https://example.com',
        targetUrl: 'https://doubleclick.net/ad/popup',
        isUserInitiated: false,
      );
      expect(res.intent, PageIntent.adPage);
      expect(res.action, PageAction.block);
      expect(res.shouldBlock, isTrue);
    });

    test('Ad domains clicked by user open in new tab with warning', () {
      final res = classifier.classifyWithContext(
        currentUrl: 'https://example.com',
        targetUrl: 'https://popads.net/click',
        isUserInitiated: true,
        isFromClick: true,
      );
      expect(res.intent, PageIntent.adPage);
      expect(res.action, PageAction.openNewTabWithWarning);
    });

    test('Auth pages are classified as authPage and open in same tab', () {
      final login = classifier.classify('https://example.com/login');
      expect(login.intent, PageIntent.authPage);
      expect(login.action, PageAction.openSameTab);

      final oauth = classifier.classify('https://accounts.google.com/o/oauth2/auth');
      expect(oauth.intent, PageIntent.authPage);
      expect(oauth.action, PageAction.openSameTab);
    });

    test('Download pages / File hosting are classified as filePage and open in same tab', () {
      final res = classifier.classify('https://mediafire.com/file/12345/document');
      expect(res.intent, PageIntent.filePage);
      expect(res.action, PageAction.openSameTab);
    });

    test('Streaming sites are classified as mediaPage and open in same tab', () {
      final yt = classifier.classify('https://youtube.com/watch?v=dQw4w9WgXcQ');
      expect(yt.intent, PageIntent.mediaPage);
      expect(yt.action, PageAction.openSameTab);
    });

    test('Normal browsing pages open in same tab', () {
      final wiki = classifier.classify('https://wikipedia.org/wiki/Flutter');
      expect(wiki.intent, PageIntent.normalBrowsing);
      expect(wiki.action, PageAction.openSameTab);
    });

    test('Empty URLs default to normal browsing', () {
      final res = classifier.classify('');
      expect(res.intent, PageIntent.normalBrowsing);
      expect(res.action, PageAction.openSameTab);
    });
  });
}
