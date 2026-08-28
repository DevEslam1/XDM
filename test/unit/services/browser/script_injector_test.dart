import 'package:dmx/features/browser/services/script_injector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ScriptInjector Tests [Browser 10/10]', () {
    test('kMediaDomains contains major streaming domains', () {
      expect(ScriptInjector.kMediaDomains.contains('youtube.com'), isTrue);
      expect(ScriptInjector.kMediaDomains.contains('vimeo.com'), isTrue);
      expect(ScriptInjector.kMediaDomains.contains('dailymotion.com'), isTrue);
      expect(ScriptInjector.kMediaDomains.contains('tiktok.com'), isTrue);
    });

    test(
        'buildForceDarkCss produces valid invert CSS with media preservation rules',
        () {
      final css = ScriptInjector.buildForceDarkCss();
      expect(css.contains('xdm-dark-applied'), isTrue);
      expect(css.contains('filter: invert'), isTrue);
      expect(css.contains('img'), isTrue);
      expect(css.contains('video'), isTrue);
    });

    test('buildSmartForceDarkScript outputs dynamic luminance detection script',
        () {
      final script = ScriptInjector.buildSmartForceDarkScript();
      expect(script.contains('xdm-dark-applied'), isTrue);
      expect(script.contains('getComputedStyle'), isTrue);
    });
  });
}
