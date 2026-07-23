/// InnerTube API constants: endpoints, API keys, and client context configs.
///
/// These keys are public — embedded in YouTube's own mobile/desktop apps.
/// Client versions tracked from yt-dlp (updated 2026.07).
library;

/// Supported InnerTube client contexts for fallback chain.
enum InnerTubeClient { android, ios, tv, mweb, web }

/// YouTube InnerTube API endpoints.
class InnerTubeEndpoints {
  InnerTubeEndpoints._();

  static const String player = 'https://www.youtube.com/youtubei/v1/player';
  static const String browse = 'https://www.youtube.com/youtubei/v1/browse';
  static const String next = 'https://www.youtube.com/youtubei/v1/next';
}

/// Public API keys per client context (embedded in YouTube apps).
const Map<InnerTubeClient, String> innerTubeApiKeys = {
  InnerTubeClient.android: 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w',
  InnerTubeClient.ios: 'AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc',
  InnerTubeClient.tv: 'AIzaSyDCU8hByM-4DrUoRUYnGn-3llEO78bcxq8',
  InnerTubeClient.mweb: 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8',
  InnerTubeClient.web: 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8',
};

/// Client context configurations sent in the request body.
/// Versions match yt-dlp INNERTUBE_CLIENTS (2026.07).
///
/// TV client requires a `thirdParty` embed context to unlock 4K adaptive
/// streams without authentication — this is what yt-dlp sends for TVHTML5.
/// `gl: 'US'` is included on all clients to ensure the full format set is
/// returned regardless of server-side geo-filtering.
const Map<InnerTubeClient, Map<String, dynamic>> innerTubeClientContexts = {
  InnerTubeClient.android: {
    'clientName': 'ANDROID',
    'clientVersion': '21.26.364',
    'androidSdkVersion': 30,
    'osName': 'Android',
    'osVersion': '11',
    'gl': 'US',
    'userAgent':
        'com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip',
    'clientNameNumeric': 3,
  },
  InnerTubeClient.ios: {
    'clientName': 'IOS',
    'clientVersion': '21.26.4',
    'deviceMake': 'Apple',
    'deviceModel': 'iPhone16,2',
    'osName': 'iPhone',
    'osVersion': '18.3.2.22D82',
    'gl': 'US',
    'userAgent':
        'com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
    'clientNameNumeric': 5,
  },
  InnerTubeClient.tv: {
    'clientName': 'TVHTML5',
    'clientVersion': '7.20260707.07.00',
    'gl': 'US',
    'userAgent':
        'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)',
    'clientNameNumeric': 7,
    // Required by yt-dlp for TVHTML5 to return 4K adaptive streams without sign-in.
    'thirdParty': {'embedUrl': 'https://www.youtube.com/'},
  },
  InnerTubeClient.mweb: {
    'clientName': 'MWEB',
    'clientVersion': '2.20260708.00.00',
    'gl': 'US',
    'userAgent':
        'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
    'clientNameNumeric': 2,
  },
  InnerTubeClient.web: {
    'clientName': 'WEB',
    'clientVersion': '2.20260708.00.00',
    'gl': 'US',
    'userAgent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'clientNameNumeric': 1,
  },
};

/// Fallback order: ANDROID has least bot detection, WEB is last resort.
/// ANDROID/IOS don't require JS player (no n-param throttling).
/// TV (with thirdParty embed context) is the primary source of 4K streams
/// without sign-in. MWEB provides additional stream coverage.
const List<InnerTubeClient> innerTubeFallbackOrder = [
  InnerTubeClient.android,
  InnerTubeClient.ios,
  InnerTubeClient.tv,
  InnerTubeClient.mweb,
  InnerTubeClient.web,
];

/// Default connection/request timeout for InnerTube HTTP calls.
const Duration innerTubeTimeout = Duration(seconds: 15);

/// Cache TTL for stream manifests (URLs expire in ~6hrs, refresh early).
const Duration streamCacheTtl = Duration(minutes: 5);
