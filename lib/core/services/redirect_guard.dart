import 'dart:async';
import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/foundation.dart';

import 'logging_service.dart';

final _log = LoggingService.logger('RedirectGuard');

/// Decision returned by [RedirectGuard.evaluate].
enum RedirectDecision {
  /// No action — page looks legitimate or no target was found.
  ignore,

  /// Auto-navigate to [RedirectResult.targetUrl] without prompting.
  autoFollow,

  /// Show the redirect confirmation sheet (low confidence / multiple candidates).
  promptUser,

  /// Detected an ad loop — block navigation.
  block,
}

class RedirectResult {
  final String? targetUrl;
  final String strategy; // how the target was discovered
  final double confidence; // 0.0 – 1.0
  final RedirectDecision decision;
  final List<String> candidates;
  const RedirectResult({
    required this.targetUrl,
    required this.strategy,
    required this.confidence,
    required this.decision,
    this.candidates = const [],
  });

  static const ignored = RedirectResult(
    targetUrl: null,
    strategy: 'none',
    confidence: 0,
    decision: RedirectDecision.ignore,
  );
}

/// Per-tab redirect state used for loop detection.
class _TabState {
  final List<String> chain = [];
  DateTime? lastAutoFollow;
  String? currentUrl;

  /// Whether the last navigation [_TabState.currentUrl] looks like an ad
  /// bridge / redirect page. Only such pages should ever be inspected for an
  /// auto-follow target — normal pages (searches, articles, ...) must not be
  /// hijacked or have their history polluted.
  bool isAdBridge = false;
  int depth = 0;
}

/// Known ad-bridge / shortener patterns. Matching host OR path-segment
/// triggers ad-page heuristics.
class _AdPatterns {
  static const hosts = <String>{
    // shorteners
    'adf.ly', 'adx.to', 'bc.vc', 'soo.gd', 'srt.am', 'u.to', 'shorte.st',
    'sh.st', 'linkshrink.net', 'link.tl', 'payshorturl.com', 'ouo.io',
    'ouo.press', 'shon.xyz', 'clk.sh', 'clksite.com', 'cuts-url.com',
    // file-locker bridges
    'uploadrar.com', 'dropapk.to', 'apkadmin.com', 'douploads.net',
    'up-load.io', 'hexupload.net', 'rockloader.co', 'speed-down.org',
    'uploadship.com', 'katfile.com', 'mexashare.com', 'subyshare.com',
    'drop.download', 'bayfiles.com', 'anonfiles.com', 'filebit.net',
    'keep2share.cc', 'k2s.cc', 'filejoker.net', 'tezfiles.com',
  };

  static const pathMarkers = <String>[
    '/go/',
    '/redirect/',
    '/dl/',
    '/download/',
    '/continue/',
    '/proceed/',
    '/step/',
    '/verify/',
  ];

  static const queryKeys = <String>{
    'go',
    'redir',
    'redirect',
    'link',
    'url',
    'target',
    'next',
    'to',
    'return',
    'returnurl',
    'return_url',
    'id',
    'file',
    'fid',
  };

  // Ad-network hosts we should NEVER auto-follow into.
  static const adNetworks = <String>{
    'doubleclick.net',
    'googlesyndication.com',
    'googletagservices.com',
    'amazon-adsystem.com',
    'taboola.com',
    'outbrain.com',
    'criteo.com',
    'adnxs.com',
    '2mdn.net',
    'moatads.com',
    'rubiconproject.com',
    'openx.net',
    'pubmatic.com',
    'propellerads.com',
    'popads.net',
    'popcash.net',
    'adcash.com',
    'adsterra.com',
  };
}

class RedirectGuard {
  RedirectGuard();

  final Map<String, _TabState> _tabs = {};

  // ── Public API ──────────────────────────────────────────────────────────

  /// Called whenever a navigation starts. Records the chain and decides
  /// whether to allow, block, or auto-replace with the real target.
  Future<RedirectResult> evaluate({
    required String tabId,
    required String navigatingTo,
  }) async {
    // FIX: Cap _tabs map size to prevent unbounded memory growth
    if (_tabs.length > 50) {
      _tabs.remove(_tabs.keys.first);
    }
    final st = _tabs.putIfAbsent(tabId, () => _TabState());
    st.currentUrl = navigatingTo;
    st.isAdBridge = _looksLikeAdBridge(navigatingTo);

    // 1) Loop guard: circular reference in chain (A -> B -> A) or rapid re-fire (<800ms) (N-02).
    if (st.chain.contains(navigatingTo) ||
        (st.chain.isNotEmpty && st.chain.last == navigatingTo) ||
        (st.lastAutoFollow != null &&
            DateTime.now().difference(st.lastAutoFollow!) <
                const Duration(milliseconds: 800))) {
      _log.warning('Redirect loop detected for $navigatingTo — blocking.');
      return const RedirectResult(
        targetUrl: null,
        strategy: 'loop-guard',
        confidence: 1.0,
        decision: RedirectDecision.block,
      );
    }

    // 2) Protocol downgrade guard (HTTPS -> HTTP) (N-03).
    if (st.chain.isNotEmpty &&
        st.chain.any((u) => u.startsWith('https://')) &&
        navigatingTo.startsWith('http://')) {
      _log.warning(
        'Insecure protocol downgrade blocked for $navigatingTo',
      );
      return const RedirectResult(
        targetUrl: null,
        strategy: 'protocol-downgrade-guard',
        confidence: 1.0,
        decision: RedirectDecision.block,
      );
    }

    // 3) Depth cap — too many hops (max 10) usually means an ad wall or redirection loop.
    if (st.depth >= 10) {
      _log.warning('Redirect depth cap reached for tab $tabId — blocking.');
      return const RedirectResult(
        targetUrl: null,
        strategy: 'depth-cap',
        confidence: 1.0,
        decision: RedirectDecision.block,
      );
    }

    st.chain.add(navigatingTo);
    if (st.chain.length > 20) st.chain.removeAt(0);
    st.depth++;

    // 3) If the destination is itself an ad network, never follow.
    if (_isAdNetwork(navigatingTo)) {
      return const RedirectResult(
        targetUrl: null,
        strategy: 'ad-network-target',
        confidence: 1.0,
        decision: RedirectDecision.block,
      );
    }

    // 4) If the destination doesn't look like an ad bridge, ignore.
    if (!_looksLikeAdBridge(navigatingTo)) {
      return RedirectResult.ignored;
    }

    // 5) We can't extract the target from the URL alone here; the caller
    //    should call [extractFromPage] once the page has loaded.
    return RedirectResult.ignored;
  }

  /// Called after the page has loaded. Runs JS extraction strategies and
  /// returns the recommended target.
  Future<RedirectResult> extractFromPage({
    required String tabId,
    required InAppWebViewController controller,
  }) async {
    final st = _tabs.putIfAbsent(tabId, () => _TabState());
    final currentUrl = st.currentUrl ?? '';
    if (currentUrl.isEmpty) return RedirectResult.ignored;

    // Only inspect pages that look like ad/redirect bridges. Running the JS
    // extraction on normal pages (Google search, articles, media sites) was
    // causing the WebView to be silently re-navigated (autoFollow) or to pop a
    // redirect sheet (promptUser) on every load — which made back/forward
    // appear to skip pages like the search results page and polluted history.
    if (!_looksLikeAdBridge(currentUrl) && !st.isAdBridge) {
      return RedirectResult.ignored;
    }

    // Run all extraction strategies in priority order via a single JS call.
    final extracted = await _runJsExtraction(controller, currentUrl);
    if (extracted == null || extracted.isEmpty) {
      return RedirectResult.ignored;
    }

    // Deduplicate + normalize.
    final candidates = <String>[];
    for (final raw in extracted) {
      final norm = _normalizeUrl(raw, baseUrl: currentUrl);
      if (norm != null && !_isAdNetwork(norm) && norm != currentUrl) {
        candidates.add(norm);
      }
    }
    if (candidates.isEmpty) return RedirectResult.ignored;

    final unique = candidates.toSet().toList();
    // Pick best candidate: prefer one whose host differs from current page
    // (ad bridges almost always redirect to a different host).
    final differentHost = unique
        .where((u) => Uri.tryParse(u)?.host != Uri.tryParse(currentUrl)?.host)
        .toList();

    final target =
        differentHost.isNotEmpty ? differentHost.first : unique.first;

    final confidence = _scoreConfidence(
      target: target,
      currentUrl: currentUrl,
      candidateCount: unique.length,
      sameHost: differentHost.isEmpty,
    );

    final decision = _decide(confidence, unique.length);

    if (decision == RedirectDecision.autoFollow) {
      st.chain.add(currentUrl);
      st.depth++;
      st.lastAutoFollow = DateTime.now();
    }

    return RedirectResult(
      targetUrl: target,
      strategy: 'js-extraction',
      confidence: confidence,
      decision: decision,
      candidates: unique,
    );
  }

  /// Reset state for a tab (e.g., user manually navigated).
  void reset(String tabId) => _tabs.remove(tabId);

  @visibleForTesting
  void addToChain(String tabId, String url) {
    final st = _tabs.putIfAbsent(tabId, () => _TabState());
    st.chain.add(url);
  }

  // ── Heuristics ──────────────────────────────────────────────────────────

  bool _looksLikeAdBridge(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();

    if (_AdPatterns.hosts.any((h) => host == h || host.endsWith('.$h'))) {
      return true;
    }
    if (_AdPatterns.pathMarkers.any((m) => path.contains(m))) return true;
    // URL carries an obvious redirect param.
    final q = uri.queryParameters;
    if (q.keys.any((k) => _AdPatterns.queryKeys.contains(k.toLowerCase()))) {
      return true;
    }
    return false;
  }

  bool _isAdNetwork(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return _AdPatterns.adNetworks
        .any((h) => host == h || host.endsWith('.$h') || host.contains(h));
  }

  String? _normalizeUrl(String raw, {required String baseUrl}) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    // Strip wrapping quotes.
    if ((s.startsWith("'") && s.endsWith("'")) ||
        (s.startsWith('"') && s.endsWith('"'))) {
      s = s.substring(1, s.length - 1);
    }
    // Reject non-http schemes.
    final lower = s.toLowerCase();
    if (lower.startsWith('javascript:') ||
        lower.startsWith('data:') ||
        lower.startsWith('blob:') ||
        lower.startsWith('vbscript:')) {
      return null;
    }
    // Try base64-decoded query params (?url=BASE64 or ?id=BASE64).
    if (s.isEmpty || s.length < 4) return null;
    final decoded = _tryDecodeBase64Url(s);
    if (decoded != null &&
        (decoded.startsWith('http://') || decoded.startsWith('https://'))) {
      s = decoded;
    }
    // Resolve relative.
    return Uri.parse(baseUrl).resolve(s).toString();
  }

  String? _tryDecodeBase64Url(String s) {
    // Only attempt if it looks base64-ish.
    if (!RegExp(r'^[A-Za-z0-9+/_-]{16,}={0,2}$').hasMatch(s)) return null;
    try {
      final normalized = s.replaceAll('-', '+').replaceAll('_', '/');
      final padded = normalized + '=' * ((4 - normalized.length % 4) % 4);
      final bytes = base64.decode(padded);
      final out = utf8.decode(bytes, allowMalformed: true);
      if (out.contains('http')) return out;
    } catch (_) {} // coverage:ignore-line
    return null;
  }

  double _scoreConfidence({
    required String target,
    required String currentUrl,
    required int candidateCount,
    required bool sameHost,
  }) {
    double score = 0.4;
    if (!sameHost) score += 0.35; // different host = strong signal
    if (candidateCount == 1) score += 0.15; // unambiguous
    // Bonus if target host looks like a CDN / file host.
    final host = Uri.tryParse(target)?.host.toLowerCase() ?? '';
    if (_AdPatterns.hosts.any((h) => host == h || host.endsWith('.$h'))) {
      score += 0.1;
    }
    final path = Uri.tryParse(target)?.path.toLowerCase() ?? '';
    final ext = path.split('.').last;
    const mediaExts = {
      'mp4',
      'mkv',
      'mp3',
      'zip',
      'rar',
      '7z',
      'apk',
      'exe',
      'iso'
    };
    if (mediaExts.contains(ext)) {
      score += 0.1; // direct file = very likely the real link
    }
    return score.clamp(0.0, 1.0);
  }

  RedirectDecision _decide(double confidence, int candidateCount) {
    if (confidence >= 0.75 && candidateCount <= 2) {
      return RedirectDecision.autoFollow;
    }
    if (confidence >= 0.4 && candidateCount <= 4) {
      return RedirectDecision.promptUser;
    }
    return RedirectDecision.ignore;
  }

  // ── JS extraction ───────────────────────────────────────────────────────

  Future<List<String>?> _runJsExtraction(
    InAppWebViewController c,
    String baseUrl,
  ) async {
    const js = r'''
(function() {
  var out = [];
  function push(u) { if (u && out.indexOf(u) < 0) out.push(u); }

  // 1. <meta http-equiv="refresh" content="0;url=...">
  document.querySelectorAll('meta[http-equiv="refresh" i]').forEach(function(m) {
    var c = m.getAttribute('content') || '';
    var i = c.toLowerCase().indexOf('url=');
    if (i >= 0) push(c.substring(i + 4).trim());
  });

  // 2. <link rel="canonical" href="...">  (only if cross-host)
  var canon = document.querySelector('link[rel="canonical" i]');
  if (canon) push(canon.href);

  // 3. JavaScript redirects embedded in <script> bodies.
  document.querySelectorAll('script').forEach(function(s) {
    var t = s.textContent || '';
    var patterns = [
      /window\.location(?:\.href)?\s*=\s*["']([^"']+)["']/gi,
      /location(?:\.href)?\s*=\s*["']([^"']+)["']/gi,
      /location\.replace\(\s*["']([^"']+)["']\s*\)/gi,
      /location\.assign\(\s*["']([^"']+)["']\s*\)/gi,
      /window\.open\(\s*["']([^"']+)["']/gi,
      /setTimeout\([^,]*, \s*\d+\s*\)\s*\{?[^}]*location[^}]*["']([^"']+)["']/gi
    ];
    patterns.forEach(function(p) {
      var m;
      while ((m = p.exec(t)) !== null) push(m[1]);
    });
  });

  // 4. data-* attributes commonly used to hide the real link.
  document.querySelectorAll('[data-url],[data-href],[data-link],[data-redirect],[data-target],[data-source]').forEach(function(el) {
    ['data-url','data-href','data-link','data-redirect','data-target','data-source'].forEach(function(k) {
      var v = el.getAttribute(k);
      if (v) push(v);
    });
  });

  // 5. Form actions (often auto-submitted with the real target).
  document.querySelectorAll('form[action]').forEach(function(f) {
    push(f.action);
  });

  // 6. Iframe src on a different host (often the real content frame).
  document.querySelectorAll('iframe[src]').forEach(function(f) {
    push(f.src);
  });

  // 7. Anchor elements whose text/class hints at "continue/download/get link".
  var hintRe = /continue|proceed|download|get\s*link|here|click|verify|go\s*to|next|skip|start/i;
  document.querySelectorAll('a[href]').forEach(function(a) {
    var txt = (a.textContent || '').trim();
    var cls = a.className || '';
    var id  = a.id || '';
    if (hintRe.test(txt) || hintRe.test(cls) || hintRe.test(id)) {
      push(a.href);
    }
  });

  // 8. Query-string encoded targets on the current URL.
  try {
    var params = new URLSearchParams(window.location.search);
    ['url','link','go','redir','redirect','target','next','to','return','returnurl','file','id'].forEach(function(k) {
      var v = params.get(k);
      if (v) push(v);
    });
  } catch (e) {}

  // 9. onClick handlers with location changes.
  document.querySelectorAll('[onclick]').forEach(function(el) {
    var oc = el.getAttribute('onclick') || '';
    var m = /location(?:\.href)?\s*=\s*["']([^"']+)["']/i.exec(oc);
    if (m) push(m[1]);
  });

  // 10. Visible text "http(s)://..." rendered on the page (some bridges
  //     literally print the link for the user to copy).
  var bodyText = (document.body && document.body.innerText) || '';
  var urlRe = /https?:\/\/[a-zA-Z0-9\-._~:\/?#\[\]@!$&'()*+,;=%]+/gi;
  var mm;
  while ((mm = urlRe.exec(bodyText)) !== null) {
    // avoid self-references
    if (mm[0].indexOf(window.location.host) < 0) push(mm[0]);
  }

  return JSON.stringify(out);
})();
''';

    try {
      final res =
          await c.evaluateJavascript(source: js).catchError((_) => null);
      if (res == null) return null;
      final decoded = jsonDecode(res.toString());
      if (decoded is List) {
        return decoded
            .map((e) => e.toString())
            .where((s) => s.isNotEmpty)
            .toList();
      }
    } catch (e) {
      _log.warning('JS extraction failed: $e');
    }
    return null;
  }
}
