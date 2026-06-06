class AdBlocker {
  static const List<String> _adDomains = [
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
    'adservice.google.com',
    'adnxs.com',
    'adsrvr.org',
    'amazon-adsystem.com',
    'criteo.com',
    'criteo.net',
    'outbrain.com',
    'taboola.com',
    'pubmatic.com',
    'rubiconproject.com',
    'openx.net',
    'indexexchange.com',
    'adsafeprotected.com',
    'moatads.com',
    'scorecardresearch.com',
    'quantserve.com',
    'zedo.com',
    'yieldmo.com',
    'adform.net',
    'adcolony.com',
    'admob.com',
    'adsymptotic.com',
    'airpush.com',
    'applovin.com',
    'chartbeat.com',
    'google-analytics.com',
    'googletagmanager.com',
    'googletagservices.com',
    'hotjar.com',
    'mixpanel.com',
    'newrelic.com',
    'segment.io',
    'sentry.io',
    'sharethrough.com',
    'smartadserver.com',
    'snap.licdn.com',
    'static.ads-twitter.com',
    'tracking.facebook.com',
    'twitter.com/i/adsct',
    'connect.facebook.net',
    'facebook.com/tr',
  ];

  static const List<String> _adUrlPatterns = [
    '/ads/',
    '/ad/',
    '/adsbygoogle',
    '/banner',
    '/popup',
    'affiliate',
    'tracker.php',
    'tracking.php',
    'click.php',
    'redirect?',
    'goto?',
  ];

  static bool shouldBlock(String url) {
    final lower = url.toLowerCase();
    for (final domain in _adDomains) {
      if (lower.contains(domain)) return true;
    }
    for (final pattern in _adUrlPatterns) {
      if (lower.contains(pattern)) return true;
    }
    return false;
  }
}
