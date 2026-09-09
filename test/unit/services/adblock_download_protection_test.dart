import 'package:dmx/features/browser/services/ad_blocker_service.dart';
import 'package:dmx/features/browser/services/adblock_filter_updater.dart';
import 'package:dmx/features/browser/services/filter_line_parser.dart';
import 'package:dmx/features/browser/services/page_intent_classifier.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AdBlocker Download Protection Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await AdBlockerService.instance.init();
      await PageIntentClassifier.instance.init();
    });

    test('isLikelyDownloadUrl accurately identifies download targets', () {
      // Direct file extensions
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/app.apk'), isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/archive.zip'), isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/installer.exe'), isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/file.rar'), isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/doc.pdf'), isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/file.torrent'), isTrue);

      // Schemes
      expect(AdBlockerService.isLikelyDownloadUrl('magnet:?xt=urn:btih:1234567890'), isTrue);

      // Path keywords
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/download/file_123'), isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/downloads/v2/app'), isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/dl/token987'), isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/getfile?id=55'), isTrue);

      // Query params
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/api?download=1'), isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/file?dl=1'), isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/view?action=download'), isTrue);

      // Non-downloads
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/blog/article'), isFalse);
      expect(AdBlockerService.isLikelyDownloadUrl('https://example.com/home'), isFalse);
    });

    test('shouldBlockUrl never blocks legitimate download URLs', () {
      final service = AdBlockerService.instance;

      // GitHub releases download
      expect(
        service.shouldBlockUrl('https://github.com/user/repo/releases/download/v1.0/app.apk'),
        isFalse,
      );

      // SourceForge download URL
      expect(
        service.shouldBlockUrl('https://downloads.sourceforge.net/project/test/setup.exe'),
        isFalse,
      );

      // Generic site download route
      expect(
        service.shouldBlockUrl('https://mysite.org/download/package.zip'),
        isFalse,
      );

      // Still blocks dedicated ad networks
      expect(
        service.shouldBlockUrl('https://doubleclick.net/ad.js'),
        isTrue,
      );
      expect(
        service.shouldBlockUrl('https://googleadservices.com/pagead/conversion.js'),
        isTrue,
      );
    });

    test('matchesUrlPath does not match download paths', () {
      final updater = AdBlockFilterUpdater.instance;

      expect(updater.matchesUrlPath('/download/my_app.apk'), isFalse);
      expect(updater.matchesUrlPath('/downloads/v1/file.zip'), isFalse);
      expect(updater.matchesUrlPath('/dl/item123'), isFalse);
      expect(updater.matchesUrlPath('/getfile/doc.pdf'), isFalse);
    });

    test('cssRules includes download button protection styles', () {
      final css = AdBlockerService.instance.cssRules;

      expect(css.contains('download'), isTrue);
      expect(css.contains('display: revert !important'), isTrue);
      expect(css.contains('pointer-events: auto !important'), isTrue);
    });

    test('FilterLineParser ignores modifiers, regexes, and download keywords', () {
      final lines = [
        r'/$popup',
        r'/$third-party',
        r'/$image',
        r'/ad/', // regex line ending with /
        r'/a',  // too short (< 4 chars)
        '/download/button', // download keyword
        '/upload/ad',       // upload keyword
        '/ads/banner123',   // legitimate ad path
      ];

      final res = FilterLineParser.parse(lines, FilterType.ads);

      expect(res.urlPatterns.contains(r'/$popup'), isFalse);
      expect(res.urlPatterns.contains(r'/$third-party'), isFalse);
      expect(res.urlPatterns.contains(r'/ad/'), isFalse);
      expect(res.urlPatterns.contains(r'/a'), isFalse);
      expect(res.urlPatterns.contains('/download/button'), isFalse);
      expect(res.urlPatterns.contains('/upload/ad'), isFalse);
      expect(res.urlPatterns.contains('/ads/banner123'), isTrue);
    });

    test('PageIntentClassifier does not classify download URLs as ads', () {
      final classifier = PageIntentClassifier.instance;

      final res = classifier.classify('https://example.com/download/app.apk');
      expect(res.intent != PageIntent.adPage, isTrue);
      expect(res.action != PageAction.block, isTrue);

      final resZip = classifier.classify('https://example.com/releases/download/v1.0.0/build.zip');
      expect(resZip.intent != PageIntent.adPage, isTrue);
      expect(resZip.action != PageAction.block, isTrue);
    });
  });
}
