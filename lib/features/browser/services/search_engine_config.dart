/// Centralized search engine definitions — single source of truth.
/// Consumed by navigation, the URL bar suggestions and the home dashboard.
class SearchEngineConfig {
  final String name;
  final String searchUrlPrefix;

  const SearchEngineConfig({
    required this.name,
    required this.searchUrlPrefix,
  });

  static const List<SearchEngineConfig> engines = [
    SearchEngineConfig(
        name: 'Google', searchUrlPrefix: 'https://google.com/search?q='),
    SearchEngineConfig(
        name: 'DuckDuckGo', searchUrlPrefix: 'https://duckduckgo.com/?q='),
    SearchEngineConfig(
        name: 'Bing', searchUrlPrefix: 'https://www.bing.com/search?q='),
    SearchEngineConfig(
        name: 'Yahoo', searchUrlPrefix: 'https://search.yahoo.com/search?p='),
    SearchEngineConfig(
        name: 'Ecosia', searchUrlPrefix: 'https://www.ecosia.org/search?q='),
    SearchEngineConfig(
        name: 'Brave', searchUrlPrefix: 'https://search.brave.com/search?q='),
    SearchEngineConfig(
        name: 'Startpage',
        searchUrlPrefix: 'https://www.startpage.com/sp/search?query='),
  ];

  /// Returns the search URL prefix for [engineName], falling back to Google.
  static String prefixFor(String engineName) {
    return engines
        .firstWhere(
          (e) => e.name == engineName,
          orElse: () => engines.first,
        )
        .searchUrlPrefix;
  }

  /// Returns true if [engineName] is a recognized engine.
  static bool isValid(String engineName) {
    return engines.any((e) => e.name == engineName);
  }
}
