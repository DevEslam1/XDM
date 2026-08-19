enum TabOrigin { userDirect, adOrPopup, redirect }

/// Encapsulates the immutable identity and core properties of a browser tab.
class BrowserTabIdentity {
  static const String canonicalBlankUrl = 'about:blank';

  final String id;
  final int createdAtMs;
  final bool isIncognito;
  TabOrigin origin;

  BrowserTabIdentity({
    required this.id,
    int? createdAtMs,
    this.isIncognito = false,
    this.origin = TabOrigin.userDirect,
  }) : createdAtMs = createdAtMs ?? 0;

  static String normalizeUrl(String? rawUrl) {
    if (rawUrl == null || rawUrl.isEmpty || rawUrl == canonicalBlankUrl) {
      return canonicalBlankUrl;
    }
    return rawUrl;
  }

  static bool isHomeUrl(String url) =>
      url.isEmpty || url == canonicalBlankUrl;
}
