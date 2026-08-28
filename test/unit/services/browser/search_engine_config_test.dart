import 'package:dmx/features/browser/services/search_engine_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SearchEngineConfig Tests [Browser 10/10]', () {
    test('contains recognized search engines', () {
      expect(SearchEngineConfig.isValid('Google'), isTrue);
      expect(SearchEngineConfig.isValid('DuckDuckGo'), isTrue);
      expect(SearchEngineConfig.isValid('Bing'), isTrue);
      expect(SearchEngineConfig.isValid('Ecosia'), isTrue);
      expect(SearchEngineConfig.isValid('Brave'), isTrue);
      expect(SearchEngineConfig.isValid('InvalidEngine'), isFalse);
    });

    test('prefixFor returns correct URL query prefix and falls back to Google',
        () {
      expect(
        SearchEngineConfig.prefixFor('DuckDuckGo'),
        equals('https://duckduckgo.com/?q='),
      );
      expect(
        SearchEngineConfig.prefixFor('Bing'),
        equals('https://www.bing.com/search?q='),
      );
      expect(
        SearchEngineConfig.prefixFor('UnknownEngine'),
        equals('https://google.com/search?q='),
      );
    });
  });
}
